import AVFoundation
import Foundation
import CadenceKit

/// EXPLORATION MODULE — the live splice half of the hybrid. Runs on its own serial queue, decoding
/// the original file chunk-by-chunk, trimming each chunk with CadenceKit's validated splice
/// (`OfflineTrimRenderer.renderMapped` — zero-crossing snap + equal-power crossfade), and scheduling
/// the trimmed PCM into an `AVAudioPlayerNode`. This is the seam the research identified: silence
/// removal is not a graph node, it's *which samples we schedule*.
///
/// Everything is anchored in SOURCE time (the file's original timeline). The producer folds each
/// chunk's realized `RenderSegment`s into a `CadenceTimelineMapBuilder` (same code the pre-render
/// pipeline uses), so the engine can map the player's output position back to an exact source
/// position and compute how much silence has actually been removed.
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

    /// Live chunk length. Smaller ⇒ faster first-audio and snappier seeks, but more chunk seams
    /// (a silence straddling a seam is under-trimmed — accepted, matches the pre-render limitation).
    private let chunkSeconds: TimeInterval = 12
    /// Keep roughly this many seconds of OUTPUT audio queued ahead of the playhead.
    private let targetAheadSeconds: TimeInterval = 24

    private let queue = DispatchQueue(label: "com.naufalmir.rhapsode.cadencelive.producer")
    private let lock = NSLock()

    // Mutable state — guarded by `lock`.
    private var settings: CadenceSettings
    private var trimEnabled: Bool
    private var cursor: TimeInterval = 0            // next source second to decode
    private var scheduledOutput: TimeInterval = 0   // cumulative OUTPUT seconds scheduled this session
    private var mapBuilder = CadenceTimelineMapBuilder()
    private var generation = 0                       // bumped on seek to drop the stale poll chain
    private var finishedDecoding = false
    /// Whole-file adaptive floor from the pre-scan (Fix A). Fed into per-chunk detection so the
    /// threshold is stable across chunk boundaries. `nil` until the pre-scan completes → detection
    /// falls back to the chunk-local floor (identical to the pre-fix behavior).
    private var globalFloorDb: Double?

    /// Poll cadence: how often (on the producer queue) we top up the scheduled buffers. Replaces
    /// completion-handler-driven refill, which deadlocked `stop()` against the node's completion
    /// queue (see file header).
    private let pollSeconds = 0.25

    init(url: URL, cutPoints: [TimeInterval], sourceDuration: TimeInterval,
         sampleRate: Double, playerNode: AVAudioPlayerNode,
         settings: CadenceSettings, trimEnabled: Bool) {
        self.url = url
        self.cutPoints = cutPoints
        self.sourceDuration = sourceDuration
        self.sampleRate = sampleRate
        self.playerNode = playerNode
        self.settings = settings
        self.trimEnabled = trimEnabled
    }

    // MARK: - Session control (called from the engine / main actor)
    //
    // CRITICAL: every `AVAudioPlayerNode` mutation (stop / scheduleBuffer / play / pause) runs on
    // `queue`, the single serial producer queue. `AVAudioPlayerNode.stop()` deadlocks if it races
    // buffer scheduling/teardown on the node's internal completion queue (confirmed via stack
    // sample); serializing every node call onto one queue makes that race impossible.

    /// Begin (or restart after a seek) a session from `sourceStart`. Stops the node, resets the
    /// session output timeline to 0 and the map to `sourceStart`-based coordinates, fills the
    /// initial buffers, and starts playback iff `resumePlaying`. All on the producer queue.
    func beginSession(fromSource sourceStart: TimeInterval, resumePlaying: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()                 // serialized with scheduleBuffer → no deadlock
            self.lock.lock()
            self.generation += 1
            let gen = self.generation
            self.cursor = max(0, min(sourceStart, self.sourceDuration))
            self.scheduledOutput = 0
            self.mapBuilder = CadenceTimelineMapBuilder()
            self.finishedDecoding = false
            self.lock.unlock()
            self.pump(gen)                          // fill initial buffers (scheduleBuffer, same queue)
            if resumePlaying { self.playerNode.play() }
        }
    }

    /// Resume from pause (no reset — the node keeps its schedule and sampleTime).
    func resume() { queue.async { [weak self] in self?.playerNode.play() } }

    /// Pause (node keeps its schedule and timeline; `beginSession` is the only reset path).
    func pause() { queue.async { [weak self] in self?.playerNode.pause() } }

    /// Stop and invalidate the current session (teardown / end-of-stream). Bumps generation so any
    /// pending poll dies.
    func stopSession() {
        queue.async { [weak self] in
            guard let self else { return }
            self.playerNode.stop()
            self.lock.lock(); self.generation += 1; self.lock.unlock()
        }
    }

    /// Reconfigure trim on/off or tier. Caller follows with `beginSession` to apply cleanly.
    func configure(settings: CadenceSettings, trimEnabled: Bool) {
        lock.lock(); self.settings = settings; self.trimEnabled = trimEnabled; lock.unlock()
    }

    /// Supply the pre-scan's global noise floor once it's computed (Fix A). Applies from the next
    /// chunk onward — no reset needed; detection just gets more stable.
    func setGlobalFloor(_ db: Double) {
        lock.lock(); self.globalFloorDb = db; lock.unlock()
    }

    /// Synchronous teardown: drains the queue (so no `scheduleBuffer` is in flight), invalidates the
    /// session, and stops the node — safe to call before stopping the engine on the main thread.
    func shutdown() {
        queue.sync {
            self.lock.lock(); self.generation += 1; self.lock.unlock()
            self.playerNode.stop()
        }
    }

    // MARK: - Snapshot for the UI (main actor)

    struct Snapshot {
        let map: CadenceTimelineMap
        let scheduledOutput: TimeInterval
        let decodedThroughSource: TimeInterval
        let finishedDecoding: Bool
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        // Build a queryable map over what's been scheduled so far (session-local trimmed axis,
        // absolute source axis).
        let map = mapBuilder.finish(sourceDuration: cursor, trimmedDuration: scheduledOutput)
        return Snapshot(map: map, scheduledOutput: scheduledOutput,
                        decodedThroughSource: cursor, finishedDecoding: finishedDecoding)
    }

    // MARK: - Production loop (producer queue)

    /// Top up the scheduled buffers to `targetAheadSeconds`, then re-arm a delayed poll (all on the
    /// producer queue). A generation mismatch (a newer `beginSession`) or end-of-decode stops the
    /// chain. Replaces completion-handler-driven refill to avoid the `stop()` deadlock.
    private func pump(_ gen: Int) {
        while true {
            lock.lock()
            let stale = gen != generation
            let played = playedOutputUnlocked()
            let ahead = scheduledOutput - played
            let done = finishedDecoding
            lock.unlock()
            if stale { return }                 // superseded session — let the chain die
            if done { return }                  // fully decoded; end detected by the engine tick
            if ahead >= targetAheadSeconds { break }
            produceOneChunk(generation: gen)
        }
        // Re-arm: keep polling until this session is superseded or fully decoded.
        queue.asyncAfter(deadline: .now() + pollSeconds) { [weak self] in self?.pump(gen) }
    }

    /// Player output seconds already consumed this session. Must be called with `lock` held only for
    /// the `scheduledOutput` read; player time is independently thread-safe.
    private func playedOutputUnlocked() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func produceOneChunk(generation gen: Int) {
        lock.lock()
        let start = cursor
        let trimming = trimEnabled
        let tierSettings = settings
        let trimmedBase = scheduledOutput
        let floor = globalFloorDb
        lock.unlock()

        guard start < sourceDuration else {
            lock.lock(); finishedDecoding = true; lock.unlock()
            return
        }
        let end = min(start + chunkSeconds, sourceDuration)

        do {
            let decoded = try AudioIO.decode(url, startSeconds: start, durationSeconds: end - start,
                                             maxSeconds: chunkSeconds + 5)
            let regions = trimming ? detectRegions(decoded, settings: tierSettings, floorDb: floor) : []
            let rendered = try OfflineTrimRenderer(settings: tierSettings)
                .renderMapped(buffer: decoded, regions: regions)

            // Bail if a seek happened while we were decoding/rendering.
            lock.lock()
            if gen != generation { lock.unlock(); return }
            let outSeconds = Double(rendered.buffer.frameLength) / sampleRate
            mapBuilder.append(segments: rendered.segments, sampleRate: sampleRate,
                              sourceBase: start, trimmedBase: trimmedBase)
            scheduledOutput += outSeconds
            cursor = end
            if cursor >= sourceDuration { finishedDecoding = true }
            lock.unlock()

            // No completion handler: scheduling is serialized on this queue, and refill is driven by
            // `pump`'s poll. Completion handlers are what deadlocked `stop()` (see header).
            playerNode.scheduleBuffer(rendered.buffer, completionHandler: nil)
        } catch {
            lock.lock(); finishedDecoding = true; lock.unlock()
        }
    }

    /// Detect silence regions for one decoded chunk (chunk-local seconds), reusing CadenceKit.
    /// `floorDb` (Fix A): the pre-scan's global floor, used in place of this chunk's local floor so
    /// detection is stable across chunk boundaries. `nil` → chunk-local floor (pre-scan not ready).
    /// The absolute-silence ceiling (Fix B) is applied inside CadenceKit via the tier settings.
    private func detectRegions(_ buffer: AVAudioPCMBuffer, settings: CadenceSettings, floorDb: Double?) -> [SilenceRegion] {
        let mono = AudioIO.downmixToMono(buffer)
        let profile = SilenceAnalyzer.profile(monoSamples: mono, sampleRate: buffer.format.sampleRate)
        return SilenceAnalyzer(settings: settings).regions(from: profile, floorOverrideDb: floorDb, speechOverrideDb: nil)
    }
}
