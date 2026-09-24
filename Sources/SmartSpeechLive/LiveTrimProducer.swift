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
    private let channelCount: Int
    private let playerNode: AVAudioPlayerNode
    private let decodeWindows: [SmartSpeechRenderUtil.Window]
    private let requestedRubberBand: Bool

    /// Live chunk length. Smaller ⇒ faster first-audio and snappier seeks, but more chunk seams
    /// (a silence straddling a seam is under-trimmed — accepted, same as the CadenceLab oracle).
    private let chunkSeconds: TimeInterval = 12
    private var maxDecodeSeconds: TimeInterval { chunkSeconds + 5 }
    /// Kept source audio decoded on each side of a removal when it cannot fit in one window.
    private let spliceHandleSeconds: TimeInterval = 0.25
    /// Keep roughly this many seconds of OUTPUT audio queued ahead of the playhead (before rate scaling).
    private let targetAheadSeconds: TimeInterval = 24

    private let queue = DispatchQueue(label: "com.naufalmir.rhapsode.cadencelive.producer",
                                      qos: .userInitiated)
    private let lock = NSLock()

    // Mutable state — guarded by `lock`.
    private var settings: SmartSpeechSettings
    private var trimEnabled: Bool
    private var cursor: TimeInterval = 0            // next source second to decode
    private var scheduledOutput: TimeInterval = 0   // cumulative player-node seconds scheduled
    private var scheduledContent: TimeInterval = 0  // cumulative trimmed-content seconds
    private var mapBuilder = SmartSpeechTimelineMapBuilder()
    private var cachedMap: SmartSpeechTimelineMap?
    private var playbackCheckpoints = [Checkpoint(playbackTime: 0, contentTime: 0)]
    private var cachedPlaybackTimeMap = PlaybackTimeMap(checkpoints: [], playbackDuration: 0,
                                                        contentDuration: 0)
    private var sessionUsesRubberBand = false
    private var rubberBandAvailable = false
    private var rubberBandStream: RubberBandStream?
    private var adaptiveSpeedEnabled = false
    private var adaptivePlans = [SemanticAudioClassifier.AdaptivePlan]()
    private var generation = 0                       // bumped on seek to drop the stale poll chain
    private var requestedSession = 0                 // last session number handed out by beginSession
    private var startedSession = 0                   // last session whose reset has run on the queue
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
    /// Exact source-domain removals planned once for the whole file. Slicing this map per chunk
    /// prevents a silence crossing a decode seam from receiving policy twice.
    private var precomputedEditMap: PlaybackEditMap?

    /// Poll cadence: how often (on the producer queue) we top up the scheduled buffers. Replaces
    /// completion-handler-driven refill, which deadlocked `stop()` against the node's completion
    /// queue (see file header).
    private let pollSeconds = 0.25
    /// Hard cap so one pump cannot decode the rest of a 20-hour book if the
    /// player-node clock is briefly stale (lock-screen config change).
    private let maxChunksPerPump = 2
    /// Diagnostic-only threshold; this does not affect refill behavior.
    private let lowAheadDiagnosticSeconds: TimeInterval = 2

    private enum DiagnosticMode: Equatable {
        case mapped
        case rollingFallback
        case original
    }

    private var diagnosticMode: DiagnosticMode?
    private var diagnosticCandidatePauseSeconds: TimeInterval = 0
    private var diagnosticCandidateMusicSeconds: TimeInterval = 0
    private var diagnosticRealizedPauseSeconds: TimeInterval = 0
    private var diagnosticRealizedMusicSeconds: TimeInterval = 0
    private var diagnosticLowAhead = false
    private var diagnosticHasData = false
    private var diagnosticSeamExtensionCount = 0
    private var diagnosticSeamExtensionSeconds: TimeInterval = 0

    /// Optional decode/render failure callback (invoked on the producer queue).
    var onError: ((Error) -> Void)?
    /// Requests a source-position rebuild on the main actor after Rubber Band fails.
    var onRubberBandFailure: (() -> Void)?

    /// Kept-open decode handle — producer queue only. Reopened after a failed read.
    private var openFile: AVAudioFile?
    /// Last accepted session-relative playhead. Reset in `beginSession`.
    private var lastGoodPlayed: TimeInterval = 0
    /// False while the engine graph is being rebuilt; `scheduleBuffer`/`play` are skipped.
    private var graphLive = true
    /// Per-chunk RMS fallback when the pre-scan has not finished. This is the only analysis
    /// pipeline used during background playback, so it remains enabled behind the lock screen.
    private var allowLiveDetect = true
    private var didLogStaleClock = false

    init(url: URL, cutPoints: [TimeInterval], sourceDuration: TimeInterval,
         sampleRate: Double, playerNode: AVAudioPlayerNode,
         settings: SmartSpeechSettings, trimEnabled: Bool,
         precomputedRegions: [SilenceRegion]? = nil, globalSpeechDb: Double? = nil,
         channelCount: Int = 1, useRubberBand: Bool = false) {
        self.url = url
        self.cutPoints = cutPoints
        self.sourceDuration = sourceDuration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.playerNode = playerNode
        self.requestedRubberBand = useRubberBand
        self.settings = settings
        self.trimEnabled = trimEnabled
        self.precomputedRegions = precomputedRegions
        if let precomputedRegions {
            self.precomputedEditMap = Self.makeEditMap(regions: precomputedRegions, settings: settings)
        }
        self.globalSpeechDb = globalSpeechDb
        self.decodeWindows = SmartSpeechRenderUtil.chunkWindows(cutPoints: cutPoints,
                                                                totalDuration: sourceDuration,
                                                                maxChunkSeconds: chunkSeconds)
#if PERSONAL_RUBBERBAND
        if useRubberBand,
           let stream = try? RubberBandStream(sampleRate: sampleRate,
                                              channelCount: channelCount,
                                              playbackRate: 1) {
            rubberBandStream = stream
            rubberBandAvailable = true
            sessionUsesRubberBand = true
        }
#endif
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
    /// Returns the session number; `Snapshot.startedSession` reaches it once the reset has run.
    @discardableResult
    func beginSession(fromSource sourceStart: TimeInterval, resumePlaying: Bool) -> Int {
        lock.lock()
        requestedSession += 1
        let session = requestedSession
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.flushDiagnosticSummary()
            self.playerNode.stop()                 // serialized with scheduleBuffer → no deadlock
            self.lock.lock()
            self.generation += 1
            let gen = self.generation
            self.startedSession = session
            self.cursor = max(0, min(sourceStart, self.sourceDuration))
            self.scheduledOutput = 0
            self.scheduledContent = 0
            self.lastGoodPlayed = 0
            self.didLogStaleClock = false
            self.graphLive = true
            self.mapBuilder = SmartSpeechTimelineMapBuilder()
            self.cachedMap = SmartSpeechTimelineMap(points: [], sourceDuration: self.cursor, trimmedDuration: 0)
            self.playbackCheckpoints = [Checkpoint(playbackTime: 0, contentTime: 0)]
            self.rubberBandFormat = nil
            self.cachedPlaybackTimeMap = PlaybackTimeMap(checkpoints: [], playbackDuration: 0,
                                                         contentDuration: 0)
            let wasRubberBandAvailable = self.rubberBandAvailable
            self.sessionUsesRubberBand = self.rubberBandAvailable && self.requestedRubberBand
            self.rubberBandStream = self.makeRubberBandStreamIfNeeded()
            if self.sessionUsesRubberBand, self.rubberBandStream == nil {
                self.rubberBandAvailable = false
                self.sessionUsesRubberBand = false
            }
            self.finishedDecoding = false
            self.allowRefill = resumePlaying
            self.resetDiagnosticStateLocked()
            let rubberBandFailedToRestart = wasRubberBandAvailable && !self.sessionUsesRubberBand
            self.lock.unlock()
            if rubberBandFailedToRestart {
                self.onRubberBandFailure?()
                return
            }
            self.produceOneChunk(generation: gen, lowAhead: false)
            if resumePlaying {
                self.playerNode.play()
                self.pump(gen)
            }
        }
        return session
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
            self.flushDiagnosticSummary()
        }
    }

    /// Reconfigure trim on/off or tier. Caller follows with `beginSession` to apply cleanly.
    func configure(settings: SmartSpeechSettings, trimEnabled: Bool) {
        lock.lock()
        self.settings = settings
        self.trimEnabled = trimEnabled
        if let precomputedRegions {
            precomputedEditMap = Self.makeEditMap(regions: precomputedRegions, settings: settings)
        }
        lock.unlock()
    }

    /// Supply the pre-scan's global noise floor once it's computed (Fix A). Applies from the next
    /// chunk onward — no reset needed; detection just gets more stable.
    func setGlobalFloor(_ db: Double) {
        lock.lock(); self.globalFloorDb = db; lock.unlock()
    }

    /// Supply pre-scanned silence regions (absolute source time) and optional floor/speech levels.
    func setRegions(_ regions: [SilenceRegion]?, floor: Double?, speech: Double?) {
        lock.lock()
        if let regions {
            precomputedRegions = regions
            precomputedEditMap = Self.makeEditMap(regions: regions, settings: settings)
        }
        if let floor { globalFloorDb = floor }
        if let speech { globalSpeechDb = speech }
        lock.unlock()
    }

    /// Installs a validated whole-file source-time edit map. Already scheduled buffers are left
    /// untouched, so the map applies only to future decode/render work (and to later seeks).
    func setPrecomputedEditMap(_ map: PlaybackEditMap) {
        lock.lock()
        precomputedEditMap = map
        lock.unlock()
    }

    /// Scale the ahead-of-playhead buffer target with playback rate (content seconds).
    func setPlaybackRate(_ rate: Float) {
        lock.lock(); playbackRate = max(0.5, min(rate, 3.0)); lock.unlock()
    }

    func setAdaptiveSpeedEnabled(_ enabled: Bool) {
        lock.lock(); adaptiveSpeedEnabled = enabled; lock.unlock()
    }

    func setAdaptivePlan(_ plan: SemanticAudioClassifier.AdaptivePlan) {
        guard case .completed = plan.analysis else { return }
        lock.lock()
        adaptivePlans.append(plan)
        let earliestRetainedSource = max(0, cursor - 60)
        adaptivePlans = adaptivePlans.filter { plan in
            guard case let .completed(coverage) = plan.analysis else { return false }
            return coverage.upperBound >= earliestRetainedSource
        }
        lock.unlock()
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
            self.flushDiagnosticSummary()
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
            self.flushDiagnosticSummary()
        }
    }

    // MARK: - Snapshot for the UI (main actor)

    struct Snapshot {
        let map: SmartSpeechTimelineMap
        let playbackTimeMap: PlaybackTimeMap
        let scheduledOutput: TimeInterval
        let usesRubberBand: Bool
        let decodedThroughSource: TimeInterval
        let finishedDecoding: Bool
        let startedSession: Int
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        let map = cachedMap ?? SmartSpeechTimelineMap(points: [], sourceDuration: cursor, trimmedDuration: scheduledContent)
        return Snapshot(map: map, playbackTimeMap: cachedPlaybackTimeMap,
                        scheduledOutput: scheduledOutput, usesRubberBand: sessionUsesRubberBand,
                        decodedThroughSource: cursor, finishedDecoding: finishedDecoding,
                        startedSession: startedSession)
    }

    // MARK: - Production loop (producer queue)

    private var effectiveTargetAhead: TimeInterval {
        if sessionUsesRubberBand { return targetAheadSeconds }
        let rate = max(1.0, Double(playbackRate))
        return targetAheadSeconds * rate
    }

    private struct PlaybackBatch {
        let buffers: [AVAudioPCMBuffer]
        let progress: [RubberBandStream.PushProgress]
    }

    private var rubberBandFormat: AVAudioFormat?

    private func makeRubberBandStreamIfNeeded() -> RubberBandStream? {
#if PERSONAL_RUBBERBAND
        guard requestedRubberBand, rubberBandAvailable else { return nil }
        return try? RubberBandStream(sampleRate: sampleRate, channelCount: channelCount,
                                     playbackRate: Double(playbackRate))
#else
        return nil
#endif
    }

    private func playbackBatch(input: AVAudioPCMBuffer?, finish: Bool,
                               playbackRate: Double? = nil) -> PlaybackBatch? {
        guard sessionUsesRubberBand else {
            return PlaybackBatch(buffers: input.map { [$0] } ?? [], progress: [])
        }
        guard let stream = rubberBandStream else {
            failRubberBand(RubberBandStream.StreamError.unavailable)
            return nil
        }

        do {
            var buffers = [AVAudioPCMBuffer]()
            var progress = [RubberBandStream.PushProgress]()
            if let input {
                rubberBandFormat = input.format
                buffers.append(try stream.process(
                    input,
                    playbackRate: playbackRate ?? currentPlaybackRate()
                ))
                if let latest = stream.pushProgress.last { progress.append(latest) }
            }
            if finish, let format = rubberBandFormat ?? input?.format {
                buffers.append(try stream.finishBuffer(format: format))
                if let latest = stream.pushProgress.last { progress.append(latest) }
            }
            return PlaybackBatch(buffers: buffers, progress: progress)
        } catch {
            failRubberBand(error)
            return nil
        }
    }

    private func failRubberBand(_ error: Error) {
        lock.lock()
        rubberBandAvailable = false
        allowRefill = false
        generation += 1
        lock.unlock()
        playerNode.stop()
        DiagnosticLog.error("Rubber Band stream failed; rebuilding with AVAudioUnitTimePitch: \(error)",
                            category: .playback)
        onRubberBandFailure?()
    }

    private func currentPlaybackRate() -> Double {
        lock.lock(); defer { lock.unlock() }
        return Double(playbackRate)
    }

    private func adaptivePlaybackRate(for sourceRange: ClosedRange<TimeInterval>) -> Double {
        lock.lock(); defer { lock.unlock() }
        let selectedRate = Double(playbackRate)
        guard adaptiveSpeedEnabled,
              sessionUsesRubberBand,
              let plan = adaptivePlans.last(where: { plan in
                  guard case let .completed(coverage) = plan.analysis else { return false }
                  return coverage.contains(sourceRange.lowerBound)
                      && coverage.contains(sourceRange.upperBound)
              })
        else {
            return selectedRate
        }
        return AdaptiveSpeedPolicy(isEnabled: true).playbackRate(
            selectedRate: selectedRate,
            windows: plan.windows,
            analysis: plan.analysis,
            sourceRange: sourceRange
        )
    }

    private func updatePlaybackClockLocked(progress: [RubberBandStream.PushProgress],
                                           contentFrames: Int) {
        if sessionUsesRubberBand, let latest = progress.last {
            scheduledOutput = Double(latest.cumulativeOutputFrames) / sampleRate
            scheduledContent = Double(latest.cumulativeInputFrames) / sampleRate
            for update in progress {
                let checkpoint = Checkpoint(
                    playbackTime: Double(update.cumulativeTargetOutputFrames) / sampleRate,
                    contentTime: Double(update.cumulativeInputFrames) / sampleRate
                )
                if let last = playbackCheckpoints.last,
                   checkpoint.playbackTime > last.playbackTime,
                   checkpoint.contentTime > last.contentTime {
                    playbackCheckpoints.append(checkpoint)
                }
            }
            cachedPlaybackTimeMap = PlaybackTimeMap(
                checkpoints: playbackCheckpoints,
                playbackDuration: Double(latest.cumulativeTargetOutputFrames) / sampleRate,
                contentDuration: scheduledContent,
                mappingIsEstimated: true
            )
        } else if !sessionUsesRubberBand {
            scheduledContent += Double(contentFrames) / sampleRate
            scheduledOutput = scheduledContent
            cachedPlaybackTimeMap = PlaybackTimeMap(
                checkpoints: [Checkpoint(playbackTime: 0, contentTime: 0)],
                playbackDuration: scheduledOutput,
                contentDuration: scheduledContent
            )
        }
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
            produceOneChunk(generation: gen, lowAhead: ahead < lowAheadDiagnosticSeconds)
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

    private enum ChunkPlan {
        case contiguous(end: TimeInterval, preferredEnd: TimeInterval)
        case boundedSplice(edit: AudioEdit, rightEnd: TimeInterval, preferredEnd: TimeInterval)
    }

    /// Select a bounded decode plan. A contiguous plan always contains source audio after a
    /// removal; an edit that cannot fit with that right handle is rendered as two short handles.
    private func chunkPlan(for cursor: TimeInterval, editMap: PlaybackEditMap?) -> ChunkPlan {
        let preferredEnd = decodeWindows.first(where: { cursor >= $0.start && cursor < $0.end })?.end
            ?? decodeWindows.last(where: { cursor >= $0.start })?.end
            ?? min(cursor + chunkSeconds, sourceDuration)

        let cappedEnd = min(preferredEnd, cursor + maxDecodeSeconds, sourceDuration)
        guard let editMap,
              let edit = editMap.edits.first(where: {
                  $0.start <= cappedEnd && $0.end > cursor
              }) else {
            return .contiguous(end: cappedEnd, preferredEnd: preferredEnd)
        }

        // A session may deliberately begin in a removed interval. There is no outgoing audio to
        // splice in that case, so the producer advances the source cursor without scheduling PCM.
        guard edit.start > cursor else {
            return .contiguous(end: cappedEnd, preferredEnd: preferredEnd)
        }

        let contiguousEnd = min(edit.end + spliceHandleSeconds, sourceDuration)
        if contiguousEnd <= cursor + maxDecodeSeconds {
            return .contiguous(end: max(cappedEnd, contiguousEnd), preferredEnd: preferredEnd)
        }

        let leftStart = max(cursor, edit.start - spliceHandleSeconds)
        if leftStart > cursor {
            return .contiguous(end: leftStart, preferredEnd: preferredEnd)
        }

        let rightEnd = min(edit.end + spliceHandleSeconds, sourceDuration)
        guard rightEnd > edit.end else {
            return .contiguous(end: min(edit.start, cappedEnd), preferredEnd: preferredEnd)
        }
        return .boundedSplice(edit: edit, rightEnd: rightEnd, preferredEnd: preferredEnd)
    }

    private func produceOneChunk(generation gen: Int, lowAhead: Bool) {
        lock.lock()
        let start = cursor
        let trimming = trimEnabled
        let liveDetect = allowLiveDetect
        let live = graphLive
        let tierSettings = settings
        let trimmedBase = scheduledContent
        let floor = globalFloorDb
        let speech = globalSpeechDb
        let editMap = precomputedEditMap
        lock.unlock()

        guard live else { return }
        guard start < sourceDuration else {
            lock.lock(); finishedDecoding = true; lock.unlock()
            return
        }
        let plan = chunkPlan(for: start, editMap: trimming ? editMap : nil)
        if case let .boundedSplice(edit, rightEnd, preferredEnd) = plan {
            produceBoundedSplice(generation: gen, start: start, edit: edit, rightEnd: rightEnd,
                                 preferredEnd: preferredEnd, settings: tierSettings, lowAhead: lowAhead)
            return
        }
        guard case let .contiguous(end, preferredEnd) = plan else { return }
        let seamExtension = max(0, end - preferredEnd)

        if trimming, let editMap,
           let containingEdit = editMap.edits.first(where: { $0.start <= start && $0.end > start }) {
            let skipEnd = min(containingEdit.end, sourceDuration)
            let tailBatch = skipEnd >= sourceDuration
                ? playbackBatch(input: nil, finish: true)
                : PlaybackBatch(buffers: [], progress: [])
            if tailBatch == nil { return }
            lock.lock()
            guard gen == generation, graphLive, cursor == start else { lock.unlock(); return }
            let skippedFrames = Int(((skipEnd - start) * sampleRate).rounded())
            if skippedFrames > 0 {
                mapBuilder.append(
                    segments: [RenderSegment(sourceStart: 0, sourceEnd: skippedFrames,
                                             trimmedStart: 0, trimmedEnd: 0)],
                    sampleRate: sampleRate, sourceBase: start, trimmedBase: trimmedBase
                )
            }
            cursor = skipEnd
            updatePlaybackClockLocked(progress: tailBatch?.progress ?? [], contentFrames: 0)
            cachedMap = mapBuilder.finish(sourceDuration: cursor, trimmedDuration: scheduledContent)
            if cursor >= sourceDuration { finishedDecoding = true }
            let skippedDuration = max(0, skipEnd - start)
            let candidatePause = containingEdit.kind == .compressPause ? skippedDuration : 0
            let candidateMusic = containingEdit.kind == .removeMusic ? skippedDuration : 0
            let isFinished = finishedDecoding
            let diagnosticEvent = recordDiagnosticLocked(
                mode: .mapped,
                candidatePause: candidatePause,
                candidateMusic: candidateMusic,
                realizedPause: candidatePause,
                realizedMusic: candidateMusic,
                lowAhead: lowAhead,
                seamExtension: 0,
                finishSession: isFinished
            )
            lock.unlock()
            for buffer in tailBatch?.buffers ?? [] where buffer.frameLength > 0 {
                playerNode.scheduleBuffer(buffer, completionHandler: nil)
            }
            if let diagnosticEvent {
                DiagnosticLog.info(diagnosticEvent.formatted, category: .smartspeech)
            }
            if isFinished { logSeamExtensionSummaryIfNeeded() }
            return
        }

        do {
            let decoded = try decodeChunk(start: start, end: end)
            let mode: DiagnosticMode
            let candidateEdits: [AudioEdit]
            let removals: [SilenceRegion]
            if trimming, let editMap {
                mode = .mapped
                candidateEdits = editMap.edits.compactMap { edit in
                    let overlapStart = max(start, edit.start)
                    let overlapEnd = min(end, edit.end)
                    guard overlapEnd > overlapStart else { return nil }
                    return AudioEdit(start: overlapStart - start, end: overlapEnd - start,
                                     kind: edit.kind)
                }
                removals = editMap.removals(in: start..<end)
            } else if trimming, liveDetect {
                mode = .rollingFallback
                let regions = detectRegions(decoded, settings: tierSettings,
                                            floorDb: floor, speechDb: speech)
                let rollingMap = Self.makeEditMap(regions: regions, settings: tierSettings)
                candidateEdits = rollingMap.edits
                removals = rollingMap.removals(in: 0..<(end - start))
            } else {
                mode = .original
                candidateEdits = []
                removals = []
            }
            let rendered = try TrimRenderer(settings: tierSettings)
                .renderMappedRemoving(buffer: decoded, removals: removals)
            let reachesEnd = end >= sourceDuration
            let selectedPlaybackRate = adaptivePlaybackRate(for: start...end)
            guard let playback = playbackBatch(input: rendered.buffer, finish: reachesEnd,
                                               playbackRate: selectedPlaybackRate) else { return }
            let candidatePause = Self.duration(of: .compressPause, in: candidateEdits)
            let candidateMusic = Self.duration(of: .removeMusic, in: candidateEdits)
            let realized = Self.realizedRemovals(in: rendered.segments,
                                                 edits: candidateEdits,
                                                 sampleRate: sampleRate)

            lock.lock()
            if gen != generation || !graphLive { lock.unlock(); return }
            mapBuilder.append(segments: rendered.segments, sampleRate: sampleRate,
                              sourceBase: start, trimmedBase: trimmedBase)
            updatePlaybackClockLocked(progress: playback.progress,
                                      contentFrames: Int(rendered.buffer.frameLength))
            cursor = end
            cachedMap = mapBuilder.finish(sourceDuration: cursor, trimmedDuration: scheduledContent)
            if cursor >= sourceDuration { finishedDecoding = true }
            let isFinished = finishedDecoding
            let diagnosticEvent = recordDiagnosticLocked(
                mode: mode,
                candidatePause: candidatePause,
                candidateMusic: candidateMusic,
                realizedPause: realized.pause,
                realizedMusic: realized.music,
                lowAhead: lowAhead,
                seamExtension: seamExtension,
                finishSession: isFinished
            )
            lock.unlock()

            for buffer in playback.buffers where buffer.frameLength > 0 {
                playerNode.scheduleBuffer(buffer, completionHandler: nil)
            }
            if let diagnosticEvent {
                DiagnosticLog.info(diagnosticEvent.formatted, category: .smartspeech)
            }
            if isFinished { logSeamExtensionSummaryIfNeeded() }
        } catch {
            lock.lock(); finishedDecoding = true; lock.unlock()
            DiagnosticLog.error("produce chunk failed: \(error)", category: .playback)
            onError?(error)
        }
    }

    /// Render a source-time removal longer than the contiguous decode cap by decoding only the
    /// final kept audio before it and initial kept audio after it. The renderer gets both sides
    /// in one synthetic buffer, so this remains a true equal-power splice rather than a hard cut.
    private func produceBoundedSplice(generation gen: Int, start: TimeInterval, edit: AudioEdit,
                                      rightEnd: TimeInterval, preferredEnd: TimeInterval,
                                      settings: SmartSpeechSettings, lowAhead: Bool) {
        do {
            let left = try decodeChunk(start: start, end: edit.start)
            let right = try decodeChunk(start: edit.end, end: rightEnd)
            let rendered = try TrimRenderer(settings: settings).renderMappedSplice(left: left, right: right)
            let translated = translatedSpliceSegments(
                rendered.segments,
                leftFrames: Int(left.frameLength),
                start: start,
                editEnd: edit.end
            )
            let reachesEnd = rightEnd >= sourceDuration
            let selectedPlaybackRate = adaptivePlaybackRate(for: start...rightEnd)
            guard let playback = playbackBatch(input: rendered.buffer, finish: reachesEnd,
                                               playbackRate: selectedPlaybackRate) else { return }
            let candidatePause = edit.kind == .compressPause ? edit.end - edit.start : 0
            let candidateMusic = edit.kind == .removeMusic ? edit.end - edit.start : 0

            lock.lock()
            guard gen == generation, graphLive, cursor == start else { lock.unlock(); return }
            let trimmedBase = scheduledContent
            mapBuilder.append(segments: translated, sampleRate: sampleRate,
                              sourceBase: start, trimmedBase: trimmedBase)
            updatePlaybackClockLocked(progress: playback.progress,
                                      contentFrames: Int(rendered.buffer.frameLength))
            cursor = rightEnd
            cachedMap = mapBuilder.finish(sourceDuration: cursor, trimmedDuration: scheduledContent)
            if cursor >= sourceDuration { finishedDecoding = true }
            let isFinished = finishedDecoding
            let diagnosticEvent = recordDiagnosticLocked(
                mode: .mapped,
                candidatePause: candidatePause,
                candidateMusic: candidateMusic,
                realizedPause: candidatePause,
                realizedMusic: candidateMusic,
                lowAhead: lowAhead,
                seamExtension: max(0, start - preferredEnd),
                finishSession: isFinished
            )
            lock.unlock()

            for buffer in playback.buffers where buffer.frameLength > 0 {
                playerNode.scheduleBuffer(buffer, completionHandler: nil)
            }
            if let diagnosticEvent {
                DiagnosticLog.info(diagnosticEvent.formatted, category: .smartspeech)
            }
            if isFinished { logSeamExtensionSummaryIfNeeded() }
        } catch {
            lock.lock(); finishedDecoding = true; lock.unlock()
            DiagnosticLog.error("produce bounded splice failed: \(error)", category: .playback)
            onError?(error)
        }
    }

    /// Convert the renderer's virtual source coordinates (`left + one removed frame + right`)
    /// back to the original source-time coordinates before appending the live timeline map.
    private func translatedSpliceSegments(_ segments: [RenderSegment], leftFrames: Int,
                                          start: TimeInterval, editEnd: TimeInterval) -> [RenderSegment] {
        let virtualRightStart = leftFrames + 1
        let rightOffset = Int(((editEnd - start) * sampleRate).rounded())
        return segments.compactMap { segment in
            if segment.sourceEnd <= leftFrames {
                return segment
            }
            guard segment.sourceStart >= virtualRightStart else { return nil }
            let offset = rightOffset - virtualRightStart
            return RenderSegment(
                sourceStart: segment.sourceStart + offset,
                sourceEnd: segment.sourceEnd + offset,
                trimmedStart: segment.trimmedStart,
                trimmedEnd: segment.trimmedEnd
            )
        }
    }

    /// Decode one window, reusing the open file. A failed read drops the handle and retries once
    /// (the file can go invalid after a media-services reset).
    private func decodeChunk(start: TimeInterval, end: TimeInterval) throws -> AVAudioPCMBuffer {
        let duration = end - start
        do {
            return try AudioIO.decode(fileForDecode(), startSeconds: start,
                                      durationSeconds: duration, maxSeconds: maxDecodeSeconds)
        } catch {
            openFile = nil
            return try AudioIO.decode(fileForDecode(), startSeconds: start,
                                      durationSeconds: duration, maxSeconds: maxDecodeSeconds)
        }
    }

    private func fileForDecode() throws -> AVAudioFile {
        if let openFile { return openFile }
        let file = try AVAudioFile(forReading: url)
        openFile = file
        return file
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

    static func makeEditMap(regions: [SilenceRegion],
                            settings: SmartSpeechSettings) -> PlaybackEditMap {
        let policy = semanticEditPolicy(for: settings)
        let semantic = regions.map {
            SemanticRegion(start: $0.start, end: $0.end, kind: .silence, confidence: 1)
        }
        return PlaybackEditMap(edits: SemanticEditPlanner(policy: policy).edits(for: semantic))
    }

    static func semanticEditPolicy(for settings: SmartSpeechSettings) -> SemanticEditPolicy {
        SemanticEditPolicy(
            minimumEditablePause: settings.minSilenceDuration,
            shortPauseUpperBound: 0.40,
            mediumPauseUpperBound: 1.20,
            shortPauseTarget: min(0.18, settings.minKeptSilence),
            mediumPauseTarget: max(settings.minKeptSilence, 0.18),
            longPauseTarget: max(settings.minKeptSilence, 0.25)
        )
    }

    private func recordDiagnosticLocked(mode: DiagnosticMode,
                                        candidatePause: TimeInterval,
                                        candidateMusic: TimeInterval,
                                        realizedPause: TimeInterval,
                                        realizedMusic: TimeInterval,
                                        lowAhead: Bool,
                                        seamExtension: TimeInterval,
                                        finishSession: Bool) -> SmartSpeechDiagnosticEvent? {
        let modeChanged = diagnosticMode != mode
        let firstLowAhead = lowAhead && !diagnosticLowAhead
        diagnosticMode = mode
        diagnosticCandidatePauseSeconds += candidatePause
        diagnosticCandidateMusicSeconds += candidateMusic
        diagnosticRealizedPauseSeconds += realizedPause
        diagnosticRealizedMusicSeconds += realizedMusic
        diagnosticLowAhead = diagnosticLowAhead || lowAhead
        diagnosticHasData = true
        if seamExtension > 0 {
            diagnosticSeamExtensionCount += 1
            diagnosticSeamExtensionSeconds += seamExtension
        }

        guard modeChanged || firstLowAhead || finishSession else { return nil }
        let event = producerDiagnosticEventLocked()
        if finishSession {
            diagnosticMode = nil
            diagnosticCandidatePauseSeconds = 0
            diagnosticCandidateMusicSeconds = 0
            diagnosticRealizedPauseSeconds = 0
            diagnosticRealizedMusicSeconds = 0
            diagnosticLowAhead = false
            diagnosticHasData = false
        }
        return event
    }

    private func producerDiagnosticEventLocked() -> SmartSpeechDiagnosticEvent? {
        guard let diagnosticMode else { return nil }
        let mode: SmartSpeechDiagnosticEvent.ProducerMode
        switch diagnosticMode {
        case .mapped: mode = .mapped
        case .rollingFallback: mode = .rollingFallback
        case .original: mode = .original
        }
        return .producer(mode: mode,
                         candidatePauseSeconds: diagnosticCandidatePauseSeconds,
                         candidateMusicSeconds: diagnosticCandidateMusicSeconds,
                         realizedPauseSeconds: diagnosticRealizedPauseSeconds,
                         realizedMusicSeconds: diagnosticRealizedMusicSeconds,
                         lowAhead: diagnosticLowAhead)
    }

    private func flushDiagnosticSummary() {
        lock.lock()
        guard diagnosticHasData else { lock.unlock(); return }
        let event = producerDiagnosticEventLocked()
        let seamCount = diagnosticSeamExtensionCount
        let seamSeconds = diagnosticSeamExtensionSeconds
        resetDiagnosticStateLocked()
        lock.unlock()

        if let event { DiagnosticLog.info(event.formatted, category: .smartspeech) }
        Self.logSeamExtensionSummary(count: seamCount, seconds: seamSeconds)
    }

    private func resetDiagnosticStateLocked() {
        diagnosticMode = nil
        diagnosticCandidatePauseSeconds = 0
        diagnosticCandidateMusicSeconds = 0
        diagnosticRealizedPauseSeconds = 0
        diagnosticRealizedMusicSeconds = 0
        diagnosticLowAhead = false
        diagnosticHasData = false
        diagnosticSeamExtensionCount = 0
        diagnosticSeamExtensionSeconds = 0
    }

    private func logSeamExtensionSummaryIfNeeded() {
        lock.lock()
        let seamCount = diagnosticSeamExtensionCount
        let seamSeconds = diagnosticSeamExtensionSeconds
        diagnosticSeamExtensionCount = 0
        diagnosticSeamExtensionSeconds = 0
        lock.unlock()
        Self.logSeamExtensionSummary(count: seamCount, seconds: seamSeconds)
    }

    private static func logSeamExtensionSummary(count: Int, seconds: TimeInterval) {
        guard count > 0 else { return }
        DiagnosticLog.info("producer seam_extensions=\(count) seam_extension_s=\(String(format: "%.3f", seconds))",
                           category: .smartspeech)
    }

    private static func duration(of kind: AudioEditKind, in edits: [AudioEdit]) -> TimeInterval {
        edits.reduce(0) { total, edit in
            total + (edit.kind == kind ? max(0, edit.end - edit.start) : 0)
        }
    }

    private static func realizedRemovals(in segments: [RenderSegment], edits: [AudioEdit],
                                         sampleRate: Double) -> (pause: TimeInterval, music: TimeInterval) {
        guard sampleRate > 0, segments.count > 1 else { return (0, 0) }
        var pause: TimeInterval = 0
        var music: TimeInterval = 0

        for index in 1..<segments.count {
            let gapStart = Double(segments[index - 1].sourceEnd) / sampleRate
            let gapEnd = Double(segments[index].sourceStart) / sampleRate
            guard gapEnd > gapStart else { continue }
            var pauseWeight: TimeInterval = 0
            var musicWeight: TimeInterval = 0
            for edit in edits {
                let overlap = max(0, min(gapEnd, edit.end) - max(gapStart, edit.start))
                if edit.kind == .compressPause {
                    pauseWeight += overlap
                } else {
                    musicWeight += overlap
                }
            }
            let weight = pauseWeight + musicWeight
            guard weight > 0 else { continue }
            let realizedGap = gapEnd - gapStart
            pause += realizedGap * pauseWeight / weight
            music += realizedGap * musicWeight / weight
        }
        return (pause, music)
    }
}
