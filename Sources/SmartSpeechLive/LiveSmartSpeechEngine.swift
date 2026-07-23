import AVFoundation
import Foundation
import Observation
import SmartSpeechKit

/// EXPLORATION MODULE — the live SmartSpeech playback engine (the AVPlayer alternative the shipped
/// feature deliberately avoids). Owns an `AVAudioEngine` graph fed by self-scheduled PCM from
/// `LiveTrimProducer`, so silences are trimmed on the fly with no rendered file on disk.
///
/// Graph (M1): `AVAudioPlayerNode → mainMixerNode → output`. M2 inserts `AVAudioUnitTimePitch`
/// between the player node and the mixer for pitch-preserving speed.
///
/// Everything the UI reads is SOURCE-domain (matching the shipped SmartSpeech invariant): `sourcePosition`
/// and the scrubber are the original file's timeline; `removedSoFar` accrues `sourceΔ − outputΔ` per
/// tick, exactly like the shipped `AudiobookPlayer.accumulateSaved`.
@MainActor
@Observable
final class LiveSmartSpeechEngine {
    // Observable UI state.
    private(set) var isLoaded = false
    private(set) var isPlaying = false
    private(set) var status = "Idle"
    private(set) var sourceDuration: TimeInterval = 0
    private(set) var sourcePosition: TimeInterval = 0
    /// Silence removed during this listen so far (seconds), accrued per tick across seeks.
    private(set) var removedSoFar: TimeInterval = 0
    /// Ideal total the whole book would save at the current tier (from the pre-scan). nil until ready.
    private(set) var projectedTotalSaved: TimeInterval?
    private(set) var prescanRegionCount: Int?
    /// Whole-file adaptive noise floor from the pre-scan (Fix A) — shown in diagnostics.
    private(set) var detectionFloorDb: Double?
    private(set) var bufferedAheadSeconds: TimeInterval = 0
    private(set) var reachedEnd = false
    var trimEnabled = true
    private(set) var preset: SmartSpeechSettings.Preset = .default
    private(set) var isMultiFile = false

    var removedSoFarPercent: Double {
        sourcePosition > 0 ? min(1, removedSoFar / max(sourcePosition, 0.001)) : 0
    }

    /// Pitch-preserving playback rate (M2). 1.0 = normal; audiobook range ~0.75–3.0.
    private(set) var rate: Float = 1.0

    // Audio graph.
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    /// M2: pitch-preserving speed, downstream of the player node (per WWDC time-effect placement).
    private let timePitch = AVAudioUnitTimePitch()
    private var producer: LiveTrimProducer?
    private var fileFormat: AVAudioFormat?

    /// True once a producer session has been started from the current origin and the node timeline
    /// is valid. `pause()` preserves it (node keeps its sampleTime); `seek()`/end/teardown clear it
    /// so the next `play()` cold-starts a fresh session. Without this, resume-after-pause would reset
    /// the producer to 0 while the node's sampleTime keeps its pre-pause value → map lookups garbage.
    private var sessionStarted = false

    // Per-tick accrual bookkeeping.
    private var haveLastTick = false
    private var lastTickOutput: TimeInterval = 0
    private var lastTickSource: TimeInterval = 0
    private var displayTask: Task<Void, Never>?
    private var source: LiveSmartSpeechSource?
    /// Pre-scan projection for every tier (`Preset.rawValue` → seconds), so tier changes update the
    /// displayed projected total without re-scanning.
    private var projectedByTier: [String: TimeInterval] = [:]

    // MARK: - Load

    func load(book: Audiobook) {
        guard let src = LiveSmartSpeechSource(book: book) else { teardown(); status = "No playable file"; return }
        configure(with: src)
    }

    #if DEBUG
    /// Debug loader that bypasses SwiftData — points the engine straight at a file URL (e.g. a
    /// bundled fixture) for smoke testing. Duration is probed from the file.
    func load(debugFileURL url: URL, preset: SmartSpeechSettings.Preset = .default) {
        guard let src = LiveSmartSpeechSource(debugFileURL: url, preset: preset) else {
            teardown(); status = "Debug file not decodable"; return
        }
        configure(with: src)
    }
    #endif

    private func configure(with src: LiveSmartSpeechSource) {
        teardown()
        self.source = src
        self.preset = src.preset
        self.sourceDuration = src.sourceDuration
        self.isMultiFile = src.isMultiFile
        self.status = "Loading…"

        // Probe the file's PCM processing format — every produced buffer uses it, so the graph is
        // connected with it and the mixer resamples to hardware.
        guard let file = try? AVAudioFile(forReading: src.url) else { status = "Undecodable (DRM?)"; return }
        let format = file.processingFormat
        self.fileFormat = format
        let sampleRate = format.sampleRate

        configureSession()
        engine.attach(playerNode)
        engine.attach(timePitch)
        timePitch.rate = rate
        timePitch.bypass = (rate == 1.0)
        // playerNode → timePitch → mixer. TimePitch pulls rate× frames upstream, so the player
        // node's own sampleTime keeps measuring CONTENT consumed (rate-independent) — see `tick`.
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()

        let producer = LiveTrimProducer(url: src.url, cutPoints: src.cutPoints,
                                        sourceDuration: src.sourceDuration, sampleRate: sampleRate,
                                        playerNode: playerNode,
                                        settings: LiveSmartSpeechTuning.settings(preset: src.preset),
                                        trimEnabled: trimEnabled)
        self.producer = producer
        producer.setPlaybackRate(rate)
        self.isLoaded = true
        self.status = "Ready"

        runPrescan(src: src)
    }

    private func runPrescan(src: LiveSmartSpeechSource) {
        let preset = src.preset
        Task.detached(priority: .userInitiated) {
            let result = try? LiveSilencePrescan.analyze(url: src.url, cutPoints: src.cutPoints, preset: preset)
            await MainActor.run { [weak self] in
                guard let self, let result else { return }
                self.projectedByTier = result.projectedSavedByTier
                self.prescanRegionCount = result.regionCount
                self.detectionFloorDb = result.globalFloorDb
                self.producer?.setRegions(result.regions,
                                          floor: result.globalFloorDb,
                                          speech: result.globalSpeechDb)
                self.refreshProjectedTotal()
            }
        }
    }

    // MARK: - Transport

    func play() {
        guard isLoaded, let producer else { return }
        do { try engine.start() } catch { status = "Engine start failed: \(error.localizedDescription)"; return }
        if !sessionStarted {
            // Cold start: producer stops + resets + fills + plays, all serialized on its queue.
            reachedEnd = false
            resetTickBaseline()
            producer.beginSession(fromSource: sourcePosition, resumePlaying: true)
            sessionStarted = true
        } else {
            // Resume from pause: node keeps its sampleTime and the producer session (map) is intact.
            producer.resume()
        }
        isPlaying = true
        status = trimEnabled ? "Playing (trim on)" : "Playing (trim off)"
        startDisplayLoop()
    }

    func pause() {
        producer?.pause()
        isPlaying = false
        status = "Paused"
    }

    func seek(toSource target: TimeInterval) {
        guard isLoaded, let producer else { return }
        let clamped = max(0, min(target, sourceDuration))
        let wasPlaying = isPlaying
        sourcePosition = clamped
        reachedEnd = false
        resetTickBaseline()
        if wasPlaying {
            do { try engine.start() } catch { status = "Engine start failed"; return }
        }
        // All node ops (stop/schedule/play) happen on the producer queue — never race stop() with
        // scheduleBuffer on the main thread (that deadlocks; see LiveTrimProducer header).
        producer.beginSession(fromSource: clamped, resumePlaying: wasPlaying)
        sessionStarted = true
        if wasPlaying {
            isPlaying = true
            startDisplayLoop()
        }
    }

    func skip(_ delta: TimeInterval) { seek(toSource: sourcePosition + delta) }

    /// Live pitch-preserving rate change (M2). Safe to set on an active node; no reschedule needed.
    /// Position tracking is unaffected because the player node's sampleTime measures content, not
    /// wall-clock — TimePitch draining faster/slower is exactly what keeps it rate-independent.
    func setRate(_ newRate: Float) {
        rate = max(0.5, min(newRate, 3.0))
        timePitch.rate = rate
        timePitch.bypass = (rate == 1.0)
        producer?.setPlaybackRate(rate)
    }

    /// Toggle trim or change tier; re-seeks to the current position so the change applies cleanly.
    func applyTrim(enabled: Bool, preset: SmartSpeechSettings.Preset) {
        self.trimEnabled = enabled
        self.preset = preset
        producer?.configure(settings: LiveSmartSpeechTuning.settings(preset: preset), trimEnabled: enabled)
        refreshProjectedTotal()   // pre-scan cached all tiers, so no re-scan needed
        seek(toSource: sourcePosition)
    }

    /// Projected total reflects the active tier, or 0 when trimming is off.
    private func refreshProjectedTotal() {
        guard !projectedByTier.isEmpty else { projectedTotalSaved = nil; return }
        projectedTotalSaved = trimEnabled ? (projectedByTier[preset.rawValue] ?? 0) : 0
    }

    // MARK: - Display loop (source position + removed-so-far + buffered)

    private func startDisplayLoop() {
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(200))
                if self?.isPlaying != true { break }
            }
        }
    }

    private func tick() {
        guard let producer else { return }
        let elapsed = playedOutput()
        let snap = producer.snapshot()
        let srcPos = snap.map.toSource(elapsed)
        bufferedAheadSeconds = max(0, snap.scheduledOutput - elapsed)
        sourcePosition = min(srcPos, sourceDuration)

        if haveLastTick {
            let dOut = elapsed - lastTickOutput
            let dSrc = srcPos - lastTickSource
            // Only accrue on normal forward advance (guards against seek/pause discontinuities).
            if dOut > 0, dOut < 2.0, dSrc >= dOut - 1e-3 {
                removedSoFar += (dSrc - dOut)
            }
        }
        lastTickOutput = elapsed
        lastTickSource = srcPos
        haveLastTick = true

        // End-of-stream detection (replaces the removed final-buffer completion callback): decoding
        // finished and the playhead has drained the scheduled output.
        if snap.finishedDecoding, snap.scheduledOutput > 0,
           elapsed >= snap.scheduledOutput - 0.15, !reachedEnd {
            handleReachedEnd()
        }
    }

    private func playedOutput() -> TimeInterval {
        guard let nodeTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func resetTickBaseline() {
        haveLastTick = false
        lastTickOutput = 0
        lastTickSource = 0
    }

    private func handleReachedEnd() {
        reachedEnd = true
        isPlaying = false
        sessionStarted = false            // next play() cold-starts (from wherever the user seeks)
        status = "Finished"
        producer?.stopSession()           // stop on the producer queue (never main — deadlock)
    }

    // MARK: - Session / teardown

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    func teardown() {
        displayTask?.cancel()
        displayTask = nil
        producer?.shutdown()              // sync-drains the producer queue + stops the node safely
        if engine.isRunning { engine.stop() }
        producer = nil
        sessionStarted = false
        isPlaying = false
        isLoaded = false
        sourcePosition = 0
        removedSoFar = 0
        projectedTotalSaved = nil
        prescanRegionCount = nil
        detectionFloorDb = nil
        projectedByTier = [:]
        reachedEnd = false
        resetTickBaseline()
    }
}
