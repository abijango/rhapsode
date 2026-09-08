import AVFoundation
import Foundation
import SmartSpeechKit

/// Live splice: decode the original file chunk-by-chunk, trim each chunk with SmartSpeechKit's
/// splice (`TrimRenderer.renderMapped` — zero-crossing snap + equal-power crossfade), and schedule
/// the trimmed PCM into an `AVAudioPlayerNode`. Silence removal is which samples we schedule,
/// not a graph node.
///
/// Everything is anchored in SOURCE time. The producer folds each chunk's realized `RenderSegment`s
/// into a `SmartSpeechTimelineMapBuilder` so the engine can map output position back to source
/// and compute how much silence has actually been removed.
///
/// `@unchecked Sendable`: all mutable state is guarded by `lock`; the `AVAudioPlayerNode` (not itself
/// Sendable) is only used for thread-safe operations (`scheduleBuffer`, `stop`).
final class LiveTrimProducer: @unchecked Sendable {
    /// A produced-and-scheduled span, session-relative output time ↔ absolute source time.
    /// Kept only for diagnostics; the authoritative mapping is the timeline map.

    // Immutable config (set at init).
    private let url: URL
    private let cutPoints: [TimeInterval]
    private let sourceDuration: TimeInterval
    private let sampleRate: Double
    private let playerNode: AVAudioPlayerNode
    private let decodeWindows: [SmartSpeechRenderUtil.Window]

    /// Live chunk length. Smaller ⇒ faster first-audio and snappier seeks, but more chunk seams
    /// (a silence straddling a seam is under-trimmed — accepted, same as the CadenceLab oracle).
    private let chunkSeconds: TimeInterval = 12
    /// Keep roughly this many seconds of OUTPUT audio queued ahead of the playhead (before rate scaling).
    private let targetAheadSeconds: TimeInterval = 24

    private let queue = DispatchQueue(label: "com.naufalmir.rhapsode.cadencelive.producer",
                                      qos: .userInitiated)
    private let lock = NSLock()

    // Mutable state — guarded by `lock`.
    private var settings: SmartSpeechSettings
    private var trimEnabled: Bool
    private var cursor: TimeInterval = 0            // next source second to decode
    private var scheduledOutput: TimeInterval = 0   // cumulative OUTPUT seconds scheduled this session
    private var mapBuilder = SmartSpeechTimelineMapBuilder()
    private var cachedMap: SmartSpeechTimelineMap?
    private var generation = 0                       // bumped on seek to drop the stale poll chain
    private var finishedDecoding = false
    private var allowRefill = false                  // false until play/resume — limits idle prefetch
    private var playbackRate: Float = 1.0
    /// Whole-file adaptive floor from the pre-scan (Fix A). Fed into per-chunk detection so the
    /// threshold is stable across chunk boundaries. `nil` until the pre-scan completes → detection
    /// falls back to the chunk-local floor (identical to the pre-fix behavior).
    private var globalFloorDb: Double?
    private var globalSpeechDb: Double?
    /// Pre-scanned silence regions in absolute source time. When set, per-chunk RMS is skipped.
    private var precomputedRegions: [SilenceRegion]?

    /// Poll cadence: how often (on the producer queue) we top up the scheduled buffers. Replaces
    /// completion-handler-driven refill, which deadlocked `stop()` against the node's completion
    /// queue (see file header).
    private let pollSeconds = 0.25
    /// Hard cap so one pump cannot decode the rest of a 20-hour book if the
    /// player-node clock is briefly stale (lock-screen config change).
    private let maxChunksPerPump = 2

    /// Optional decode/render failure callback (invoked on the producer queue).
    var onError: ((Error) -> Void)?

    /// Kept-open decode handle — producer queue only. Reopened after a failed read.
    private var openFile: AVAudioFile?
    /// Last accepted session-relative playhead. Reset in `beginSession`.
    private var lastGoodPlayed: TimeInterval = 0
    /// False while the engine graph is being rebuilt; `scheduleBuffer`/`play` are skipped.
    private var graphLive = true
    /// Per-chunk RMS when the pre-scan has not finished. Disabled in the background
    /// so lock-screen playback does not run a second decode/analysis pipeline.
    private var allowLiveDetect = true
    private var didLogStaleClock = false

    init(url: URL, cutPoints: [TimeInterval], sourceDuration: TimeInterval,
         sampleRate: Double, playerNode: AVAudioPlayerNode,
         settings: SmartSpeechSettings, trimEnabled: Bool,
         precomputedRegions: [SilenceRegion]? = nil, globalSpeechDb: Double? = nil) {
        self.url = url
        self.cutPoints = cutPoints
        self.sourceDuration = sourceDuration
        self.sampleRate = sampleRate
        self.playerNode = playerNode
        self.settings = settings
        self.trimEnabled = trimEnabled
        self.precomputedRegions = precomputedRegions
        self.globalSpeechDb = globalSpeechDb
        self.decodeWindows = SmartSpeechRenderUtil.chunkWindows(cutPoints: cutPoints,
                                                                totalDuration: sourceDuration,
                                                                maxChunkSeconds: chunkSeconds)
    }

    // MARK: - Session control (called from the engine / main actor)
    //
    // CRITICAL: every `AVAudioPlayerNode` mutation (stop / scheduleBuffer / play / pause) runs on
    // `queue`, the single serial producer queue. `AVAudioPlayerNode.stop()` deadlocks if it races
    // buffer scheduling/teardown on the node's internal completion queue (confirmed via stack
    // sample); serializing every node call onto one queue makes that race impossible.

    /// Begin (or restart after a seek) a session from `sourceStart`. Stops the node, resets the
    /// session output timeline to 0 and the map to `sourceStart`-based coordinates, schedules one
    /// chunk for low seek latency, and starts playback iff `resumePlaying`. Further refill is async.
    func beginSession(fromSource sourceStart: TimeInterval, resumePlaying: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()                 // serialized with scheduleBuffer → no deadlock
            self.lock.lock()
            self.generation += 1
            let gen = self.generation
            self.cursor = max(0, min(sourceStart, self.sourceDuration))
            self.scheduledOutput = 0
            self.lastGoodPlayed = 0
            self.didLogStaleClock = false
            self.graphLive = true
            self.mapBuilder = SmartSpeechTimelineMapBuilder()
            self.cachedMap = SmartSpeechTimelineMap(points: [], sourceDuration: self.cursor, trimmedDuration: 0)
            self.finishedDecoding = false
            self.allowRefill = resumePlaying
            self.lock.unlock()
            self.produceOneChunk(generation: gen)
            if resumePlaying {
                self.playerNode.play()
                self.pump(gen)
            }
        }
    }

    /// Resume from pause (no reset — the node keeps its schedule and sampleTime).
    func resume() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.allowRefill = true
            self.graphLive = true
            let gen = self.generation
            self.lock.unlock()
            self.playerNode.play()
            self.pump(gen)
        }
    }

    /// Pause (node keeps its schedule and timeline; `beginSession` is the only reset path).
    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.allowRefill = false
            self.lock.unlock()
            self.playerNode.pause()
        }
    }

    /// Stop and invalidate the current session (teardown / end-of-stream). Bumps generation so any
    /// pending poll dies.
    func stopSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.lock.lock()
            self.generation += 1
            self.allowRefill = false
            self.lock.unlock()
        }
    }

    /// Reconfigure trim on/off or tier. Caller follows with `beginSession` to apply cleanly.
    func configure(settings: SmartSpeechSettings, trimEnabled: Bool) {
        lock.lock(); self.settings = settings; self.trimEnabled = trimEnabled; lock.unlock()
    }

    /// Supply the pre-scan's global noise floor once it's computed (Fix A). Applies from the next
    /// chunk onward — no reset needed; detection just gets more stable.
    func setGlobalFloor(_ db: Double) {
        lock.lock(); self.globalFloorDb = db; lock.unlock()
    }

    /// Supply pre-scanned silence regions (absolute source time) and optional floor/speech levels.
    func setRegions(_ regions: [SilenceRegion]?, floor: Double?, speech: Double?) {
        lock.lock()
        if let regions { precomputedRegions = regions }
        if let floor { globalFloorDb = floor }
        if let speech { globalSpeechDb = speech }
        lock.unlock()
    }

    /// Scale the ahead-of-playhead buffer target with playback rate (content seconds).
    func setPlaybackRate(_ rate: Float) {
        lock.lock(); playbackRate = max(0.5, min(rate, 3.0)); lock.unlock()
    }

    /// Allow per-chunk RMS only when the UI is foregrounded. Lock-screen playback
    /// waits for the pre-scan (or plays the chunk untrimmed).
    func setLiveDetectionEnabled(_ enabled: Bool) {
        lock.lock(); allowLiveDetect = enabled; lock.unlock()
    }

    /// Drain in-flight decode/schedule so the owner can stop or reconnect the engine
    /// without racing `scheduleBuffer` (AudioToolbox SIGTRAP on a torn-down graph).
    func pauseForGraphChange() {
        queue.sync {
            self.lock.lock()
            self.generation += 1
            self.allowRefill = false
            self.graphLive = false
            self.lock.unlock()
        }
    }

    /// Synchronous teardown: drains the queue (so no `scheduleBuffer` is in flight), invalidates the
    /// session, and stops the node — safe to call before stopping the engine on the main thread.
    func shutdown() {
        queue.sync {
            self.lock.lock()
            self.generation += 1
            self.allowRefill = false
            self.graphLive = false
            self.lock.unlock()
            self.playerNode.stop()
            self.openFile = nil
        }
    }

    // MARK: - Snapshot for the UI (main actor)

    struct Snapshot {
        let map: SmartSpeechTimelineMap
        let scheduledOutput: TimeInterval
        let decodedThroughSource: TimeInterval
        let finishedDecoding: Bool
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let map = cachedMap ?? SmartSpeechTimelineMap(points: [], sourceDuration: cursor, trimmedDuration: scheduledOutput)
        return Snapshot(map: map, scheduledOutput: scheduledOutput,
                        decodedThroughSource: cursor, finishedDecoding: finishedDecoding)
    }

    // MARK: - Production loop (producer queue)

    private var effectiveTargetAhead: TimeInterval {
        let rate = max(1.0, Double(playbackRate))
        return targetAheadSeconds * rate
    }

    /// Top up the scheduled buffers to `effectiveTargetAhead`, then re-arm a delayed poll (all on the
    /// producer queue). A generation mismatch (a newer `beginSession`) or end-of-decode stops the
    /// chain. Replaces completion-handler-driven refill to avoid the `stop()` deadlock.
    private func pump(_ gen: Int) {
        var produced = 0
        while true {
            lock.lock()
            let stale = gen != generation
            let playing = allowRefill
            let live = graphLive
            let played = playedOutputUnlocked()
            let ahead = scheduledOutput - played
            let done = finishedDecoding
            let target = effectiveTargetAhead
            lock.unlock()
            if stale || !playing || !live { return }
            if done { return }
            if ahead >= target { break }
            if produced >= maxChunksPerPump { break }
            produceOneChunk(generation: gen)
            produced += 1
        }
        queue.asyncAfter(deadline: .now() + pollSeconds) { [weak self] in self?.pump(gen) }
    }

    /// Player output seconds already consumed this session. Must be called with `lock` held only for
    /// the `scheduledOutput` / `lastGoodPlayed` read; player time is independently thread-safe.
    private func playedOutputUnlocked() -> TimeInterval {
        let raw: TimeInterval?
        if let nodeTime = playerNode.lastRenderTime,
           let playerTime = playerNode.playerTime(forNodeTime: nodeTime) {
            raw = Double(playerTime.sampleTime) / playerTime.sampleRate
        } else {
            raw = nil
        }
        let played = LivePlaybackClock.sessionPlayed(
            rawSeconds: raw, scheduledOutput: scheduledOutput, lastGood: lastGoodPlayed
        )
        if let raw, raw.isFinite, raw > scheduledOutput + LivePlaybackClock.scheduledSlack,
           !didLogStaleClock {
            didLogStaleClock = true
            DiagnosticLog.info(
                "ignored stale player time \(String(format: "%.1f", raw))s scheduled=\(String(format: "%.1f", scheduledOutput))s",
                category: .playback
            )
        }
        lastGoodPlayed = played
        return played
    }

    /// End of the current decode window containing `cursor` (respects cut points + chunk cap).
    private func chunkEnd(for cursor: TimeInterval) -> TimeInterval {
        for w in decodeWindows where cursor >= w.start && cursor < w.end {
            return w.end
        }
        if let last = decodeWindows.last, cursor >= last.start {
            return min(last.end, sourceDuration)
        }
        return min(cursor + chunkSeconds, sourceDuration)
    }

    private func produceOneChunk(generation gen: Int) {
        lock.lock()
        let start = cursor
        let trimming = trimEnabled
        let liveDetect = allowLiveDetect
        let live = graphLive
        let tierSettings = settings
        let trimmedBase = scheduledOutput
        let floor = globalFloorDb
        let speech = globalSpeechDb
        let allRegions = precomputedRegions
        lock.unlock()

        guard live else { return }
        guard start < sourceDuration else {
            lock.lock(); finishedDecoding = true; lock.unlock()
            return
        }
        let end = chunkEnd(for: start)

        do {
            let decoded = try decodeChunk(start: start, end: end)
            let regions: [SilenceRegion]
            if trimming, let allRegions {
                regions = sliceRegions(allRegions, chunkStart: start, chunkEnd: end)
            } else if trimming, liveDetect {
                regions = detectRegions(decoded, settings: tierSettings, floorDb: floor, speechDb: speech)
            } else {
                regions = []
            }
            let rendered = try TrimRenderer(settings: tierSettings)
                .renderMapped(buffer: decoded, regions: regions)

            lock.lock()
            if gen != generation || !graphLive { lock.unlock(); return }
            let outSeconds = Double(rendered.buffer.frameLength) / sampleRate
            mapBuilder.append(segments: rendered.segments, sampleRate: sampleRate,
                              sourceBase: start, trimmedBase: trimmedBase)
            scheduledOutput += outSeconds
            cursor = end
            cachedMap = mapBuilder.finish(sourceDuration: cursor, trimmedDuration: scheduledOutput)
            if cursor >= sourceDuration { finishedDecoding = true }
            lock.unlock()

            playerNode.scheduleBuffer(rendered.buffer, completionHandler: nil)
        } catch {
            lock.lock(); finishedDecoding = true; lock.unlock()
            DiagnosticLog.error("produce chunk failed: \(error)", category: .playback)
            onError?(error)
        }
    }

    /// Decode one window, reusing the open file. A failed read drops the handle and retries once
    /// (the file can go invalid after a media-services reset).
    private func decodeChunk(start: TimeInterval, end: TimeInterval) throws -> AVAudioPCMBuffer {
        let duration = end - start
        do {
            return try AudioIO.decode(fileForDecode(), startSeconds: start,
                                      durationSeconds: duration, maxSeconds: chunkSeconds + 5)
        } catch {
            openFile = nil
            return try AudioIO.decode(fileForDecode(), startSeconds: start,
                                      durationSeconds: duration, maxSeconds: chunkSeconds + 5)
        }
    }

    private func fileForDecode() throws -> AVAudioFile {
        if let openFile { return openFile }
        let file = try AVAudioFile(forReading: url)
        openFile = file
        return file
    }

    /// Slice absolute-source regions overlapping `[chunkStart, chunkEnd)` into chunk-local seconds.
    private func sliceRegions(_ regions: [SilenceRegion],
                              chunkStart: TimeInterval, chunkEnd: TimeInterval) -> [SilenceRegion] {
        regions.compactMap { region in
            let overlapStart = max(region.start, chunkStart)
            let overlapEnd = min(region.end, chunkEnd)
            guard overlapEnd > overlapStart else { return nil }
            return SilenceRegion(start: overlapStart - chunkStart, end: overlapEnd - chunkStart)
        }
    }

    /// Detect silence regions for one decoded chunk (chunk-local seconds), reusing SmartSpeechKit.
    /// `floorDb` (Fix A): the pre-scan's global floor, used in place of this chunk's local floor so
    /// detection is stable across chunk boundaries. `nil` → chunk-local floor (pre-scan not ready).
    /// The absolute-silence ceiling (Fix B) is applied inside SmartSpeechKit via the tier settings.
    private func detectRegions(_ buffer: AVAudioPCMBuffer, settings: SmartSpeechSettings,
                               floorDb: Double?, speechDb: Double?) -> [SilenceRegion] {
        let mono = AudioIO.downmixToMono(buffer)
        let profile = SilenceAnalyzer.profile(monoSamples: mono, sampleRate: buffer.format.sampleRate)
        return SilenceAnalyzer(settings: settings)
            .regions(from: profile, floorOverrideDb: floorDb, speechOverrideDb: speechDb)
    }
}
