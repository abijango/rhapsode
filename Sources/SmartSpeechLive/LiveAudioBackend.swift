import AVFoundation
import Foundation
import SmartSpeechKit

/// Production live-trimming audio backend that `AudiobookPlayer` owns in place of `AVPlayer`.
///
/// Plays ONE file at a time (the owner drives multi-file sequencing), speaking **source time**
/// natively: the owner asks for `currentSource` and calls `seek(toSource:)`, and this backend owns the
/// source↔output mapping internally (built live by `LiveTrimProducer` when trimming, or identity when
/// not). Graph: `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`. The owner keeps AVAudioSession
/// config, interruption/route handling, Now Playing, remote commands, sync and stats.
///
/// Two modes:
/// - **live** (`trimEnabled: true`): decode the original, trim silence on the fly; `currentSource`
///   comes from the producer's live map.
/// - **original** (`trimEnabled: false`): play the file as-is; `currentSource == sessionStart + output`.
@MainActor
final class LiveAudioBackend {
    /// Fired ~4×/s while playing (drives the owner's `tick`).
    var onTick: (@MainActor () -> Void)?
    /// Fired once when the current file finishes (drives the owner's end-of-track advance).
    var onReachedEnd: (@MainActor () -> Void)?

    private(set) var isPlaying = false
    var rate: Float = 1.0 {
        didSet {
            let r = max(0.5, min(rate, 3.0))
            timePitch.rate = r
            timePitch.bypass = (r == 1.0)
            producer?.setPlaybackRate(r)
        }
    }

    /// Fired when media services reset and the graph must be rebuilt by the owner.
    var onEngineInvalidated: (@MainActor () -> Void)?

    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()
    private var producer: LiveTrimProducer?
    private var attached = false
    private var connectedFormat: AVAudioFormat?

    private var trimEnabled = false
    private var sessionSourceStart: TimeInterval = 0
    private var sourceDuration: TimeInterval = 0
    private var globalFloorDb: Double?
    private var prescanRegions: [SilenceRegion]?
    private var globalSpeechDb: Double?
    private var reachedEndFired = false
    private var displayTask: Task<Void, Never>?
    private var configObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?
    private var isHandlingConfigChange = false
    /// Last trustworthy source position — config-change handlers must not read the
    /// node clock after the engine has already stopped.
    private var lastKnownSource: TimeInterval = 0
    private var lastGoodOutput: TimeInterval = 0
    private var displayIntervalMs: UInt64 = 250

    // MARK: Load

    /// Load one file and prepare a session starting at `startSource` (source-domain seconds within
    /// this file). Does not begin playback — the owner calls `play()`.
    func load(url: URL, sourceDuration: TimeInterval, cutPoints: [TimeInterval],
              startSource: TimeInterval, trimEnabled: Bool, preset: SmartSpeechSettings.Preset,
              globalFloorDb: Double?) {
        installObserversIfNeeded()
        displayTask?.cancel(); displayTask = nil
        isPlaying = false
        producer?.shutdown()
        producer = nil
        lastKnownSource = max(0, min(startSource, sourceDuration))
        lastGoodOutput = 0
        prescanRegions = nil
        globalSpeechDb = nil
        guard let file = try? AVAudioFile(forReading: url) else {
            DiagnosticLog.error("audio file open failed \(url.lastPathComponent)", category: .playback)
            onReachedEnd?()
            return
        }
        let format = file.processingFormat

        let needsReconnect = connectedFormat == nil
            || connectedFormat?.sampleRate != format.sampleRate
            || connectedFormat?.channelCount != format.channelCount

        if !attached {
            engine.attach(playerNode)
            engine.attach(timePitch)
            attached = true
        }
        if needsReconnect {
            if engine.isRunning { engine.stop() }
            engine.connect(playerNode, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }

        let r = max(0.5, min(rate, 3.0))
        timePitch.rate = r
        timePitch.bypass = (r == 1.0)
        engine.prepare()

        self.trimEnabled = trimEnabled
        self.sourceDuration = sourceDuration
        self.sessionSourceStart = max(0, min(startSource, sourceDuration))
        self.lastKnownSource = self.sessionSourceStart
        self.globalFloorDb = globalFloorDb
        self.reachedEndFired = false

        let p = LiveTrimProducer(url: url, cutPoints: cutPoints, sourceDuration: sourceDuration,
                                 sampleRate: format.sampleRate, playerNode: playerNode,
                                 settings: LiveSmartSpeechTuning.settings(preset: preset),
                                 trimEnabled: trimEnabled,
                                 precomputedRegions: prescanRegions,
                                 globalSpeechDb: globalSpeechDb)
        if let gf = globalFloorDb { p.setGlobalFloor(gf) }
        if let regions = prescanRegions {
            p.setRegions(regions, floor: globalFloorDb, speech: globalSpeechDb)
        }
        p.setPlaybackRate(r)
        producer = p
        p.beginSession(fromSource: sessionSourceStart, resumePlaying: false)
    }

    /// Apply a completed pre-scan: floor, speech level, and silence regions for the active tier.
    func applyPrescan(_ result: LiveSilencePrescanResult) {
        globalFloorDb = result.globalFloorDb
        globalSpeechDb = result.globalSpeechDb
        prescanRegions = result.regions
        producer?.setRegions(result.regions, floor: result.globalFloorDb, speech: result.globalSpeechDb)
    }

    /// Supply pre-scanned regions without a full prescan result (e.g. when only floor was known first).
    func setRegions(_ regions: [SilenceRegion], floor: Double?, speech: Double?) {
        if let f = floor { globalFloorDb = f }
        if let s = speech { globalSpeechDb = s }
        prescanRegions = regions
        producer?.setRegions(regions, floor: floor, speech: speech)
    }

    // MARK: Transport

    func play() {
        guard producer != nil else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            DiagnosticLog.error("audio engine start failed: \(error.localizedDescription)", category: .playback)
            return
        }
        producer?.resume()
        isPlaying = true
        startDisplayLoop()
    }

    func pause() {
        producer?.pause()
        isPlaying = false
        displayTask?.cancel(); displayTask = nil
    }

    /// Seek within the current file to `s` source-domain seconds.
    func seek(toSource s: TimeInterval) {
        guard producer != nil else { return }
        let clamped = max(0, min(s, sourceDuration))
        sessionSourceStart = clamped
        lastKnownSource = clamped
        lastGoodOutput = 0
        reachedEndFired = false
        if isPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            try? engine.start()
        }
        producer?.beginSession(fromSource: clamped, resumePlaying: isPlaying)
    }

    func setGlobalFloor(_ db: Double) {
        globalFloorDb = db
        producer?.setGlobalFloor(db)
    }

    /// Foreground: 4 Hz Now Playing ticks + live RMS fallback. Background / lock
    /// screen: 1 Hz ticks and no live RMS (the pre-scan is also paused by the owner).
    func setAppForegrounded(_ foreground: Bool) {
        displayIntervalMs = foreground ? 250 : 1000
        producer?.setLiveDetectionEnabled(foreground)
    }

    func stop() {
        displayTask?.cancel(); displayTask = nil
        producer?.shutdown(); producer = nil
        if engine.isRunning { engine.stop() }
        isPlaying = false
    }

    // MARK: Position (source-domain)

    /// Output seconds consumed this session (session-relative; resets on load/seek).
    var currentOutput: TimeInterval {
        let raw: TimeInterval?
        if let nodeTime = playerNode.lastRenderTime,
           let pt = playerNode.playerTime(forNodeTime: nodeTime) {
            raw = Double(pt.sampleTime) / pt.sampleRate
        } else {
            raw = nil
        }
        let scheduled = producer?.snapshot().scheduledOutput ?? lastGoodOutput
        let played = LivePlaybackClock.sessionPlayed(
            rawSeconds: raw, scheduledOutput: scheduled, lastGood: lastGoodOutput
        )
        lastGoodOutput = played
        return played
    }

    /// Absolute source-domain position within the current file.
    var currentSource: TimeInterval {
        let out = currentOutput
        let value: TimeInterval
        if trimEnabled, let snap = producer?.snapshot(), !snap.map.points.isEmpty {
            value = min(max(0, snap.map.toSource(out)), sourceDuration)
        } else {
            value = min(sessionSourceStart + out, sourceDuration)
        }
        lastKnownSource = value
        return value
    }

    /// Seconds of output audio buffered ahead of the playhead (diagnostics).
    var bufferedAheadSeconds: TimeInterval {
        guard let snap = producer?.snapshot() else { return 0 }
        return max(0, snap.scheduledOutput - currentOutput)
    }

    // MARK: Internals

    private func installObserversIfNeeded() {
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.handleEngineConfigurationChange() }
            }
        }
        if mediaResetObserver == nil {
            mediaResetObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.handleMediaServicesReset() }
            }
        }
    }

    private func handleEngineConfigurationChange() {
        guard !isHandlingConfigChange else { return }
        guard producer != nil, let format = connectedFormat, attached else { return }
        isHandlingConfigChange = true

        let wasPlaying = isPlaying
        let src = lastKnownSource
        DiagnosticLog.info(
            "engine config change running=\(engine.isRunning) playing=\(wasPlaying) src=\(String(format: "%.1f", src))",
            category: .playback
        )

        // Drain in-flight scheduleBuffer before touching the graph.
        producer?.pauseForGraphChange()

        if engine.isRunning {
            // Still running — do not stop/reconnect. That retriggers this
            // notification and used to reset the session clock (CPU runaway).
            if wasPlaying { producer?.resume() }
            releaseConfigChangeGuard()
            return
        }

        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        engine.prepare()

        if wasPlaying {
            try? AVAudioSession.sharedInstance().setActive(true)
            do {
                try engine.start()
            } catch {
                DiagnosticLog.error("engine restart after config change failed: \(error.localizedDescription)", category: .playback)
                releaseConfigChangeGuard()
                return
            }
            lastGoodOutput = 0
            reachedEndFired = false
            producer?.beginSession(fromSource: src, resumePlaying: true)
            isPlaying = true
            startDisplayLoop()
        } else {
            lastGoodOutput = 0
            producer?.beginSession(fromSource: src, resumePlaying: false)
        }
        releaseConfigChangeGuard()
    }

    /// Config-change notifications are delivered asynchronously; hold the guard
    /// briefly so our own reconnect/start is not handled as a fresh change.
    private func releaseConfigChangeGuard() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            isHandlingConfigChange = false
        }
    }

    private func handleMediaServicesReset() {
        DiagnosticLog.error("media services reset — rebuilding graph", category: .playback)
        let wasPlaying = isPlaying
        producer?.shutdown()
        producer = nil
        if engine.isRunning { engine.stop() }
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        timePitch = AVAudioUnitTimePitch()
        timePitch.rate = max(0.5, min(rate, 3.0))
        timePitch.bypass = (rate == 1.0)
        attached = false
        connectedFormat = nil
        isPlaying = wasPlaying
        installObserversIfNeeded()
        onEngineInvalidated?()
    }

    private func startDisplayLoop() {
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                self.onTick?()
                self.checkEnd()
                try? await Task.sleep(for: .milliseconds(self.displayIntervalMs))
            }
        }
    }

    private func checkEnd() {
        guard !reachedEndFired, let snap = producer?.snapshot() else { return }
        if snap.finishedDecoding, snap.scheduledOutput > 0, currentOutput >= snap.scheduledOutput - 0.15 {
            reachedEndFired = true
            isPlaying = false
            displayTask?.cancel(); displayTask = nil
            onReachedEnd?()
        }
    }
}
