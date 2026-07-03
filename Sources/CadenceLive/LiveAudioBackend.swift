import AVFoundation
import Foundation
import CadenceKit

/// Production live-trimming audio backend that `AudiobookPlayer` owns in place of `AVPlayer`.
///
/// Plays ONE file at a time (the owner drives multi-file sequencing), speaking **source time**
/// natively: the owner asks for `currentSource` and calls `seek(toSource:)`, and this backend owns the
/// source↔output mapping internally (built live by `LiveTrimProducer` when trimming, or identity when
/// not). Graph: `AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`. The owner keeps AVAudioSession
/// config, interruption/route handling, Now Playing, remote commands, sync and stats.
///
/// Two modes for now (batch/pre-rendered static-map mode is added in WP5):
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
    var rate: Float = 1.0 { didSet { timePitch.rate = max(0.5, min(rate, 3.0)) } }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var producer: LiveTrimProducer?
    private var attached = false
    private var connectedFormat: AVAudioFormat?

    private var trimEnabled = false
    private var sessionSourceStart: TimeInterval = 0
    private var sourceDuration: TimeInterval = 0
    private var globalFloorDb: Double?
    private var reachedEndFired = false
    private var displayTask: Task<Void, Never>?

    // MARK: Load

    /// Load one file and prepare a session starting at `startSource` (source-domain seconds within
    /// this file). Does not begin playback — the owner calls `play()`.
    func load(url: URL, sourceDuration: TimeInterval, cutPoints: [TimeInterval],
              startSource: TimeInterval, trimEnabled: Bool, preset: CadenceSettings.Preset,
              globalFloorDb: Double?) {
        producer?.shutdown()
        producer = nil
        guard let file = try? AVAudioFile(forReading: url) else { onReachedEnd?(); return }
        let format = file.processingFormat

        // (Re)wire the graph for this file's format. Stop the engine first so connect() can't race
        // buffer scheduling (see LiveTrimProducer header — all node mutation is otherwise serialized).
        if engine.isRunning { engine.stop() }
        if !attached { engine.attach(playerNode); engine.attach(timePitch); attached = true }
        if connectedFormat == nil || connectedFormat?.sampleRate != format.sampleRate
            || connectedFormat?.channelCount != format.channelCount {
            engine.connect(playerNode, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            connectedFormat = format
        }
        timePitch.rate = max(0.5, min(rate, 3.0))
        engine.prepare()

        self.trimEnabled = trimEnabled
        self.sourceDuration = sourceDuration
        self.sessionSourceStart = max(0, min(startSource, sourceDuration))
        self.globalFloorDb = globalFloorDb
        self.reachedEndFired = false

        let p = LiveTrimProducer(url: url, cutPoints: cutPoints, sourceDuration: sourceDuration,
                                 sampleRate: format.sampleRate, playerNode: playerNode,
                                 settings: LiveCadenceTuning.settings(preset: preset),
                                 trimEnabled: trimEnabled)
        if let gf = globalFloorDb { p.setGlobalFloor(gf) }
        producer = p
        p.beginSession(fromSource: sessionSourceStart, resumePlaying: false)
    }

    // MARK: Transport

    func play() {
        guard producer != nil else { return }
        do { try engine.start() } catch { return }
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
        reachedEndFired = false
        if isPlaying { try? engine.start() }
        producer?.beginSession(fromSource: clamped, resumePlaying: isPlaying)
    }

    func setGlobalFloor(_ db: Double) {
        globalFloorDb = db
        producer?.setGlobalFloor(db)
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
        guard let nodeTime = playerNode.lastRenderTime,
              let pt = playerNode.playerTime(forNodeTime: nodeTime) else { return 0 }
        return Double(pt.sampleTime) / pt.sampleRate
    }

    /// Absolute source-domain position within the current file.
    var currentSource: TimeInterval {
        let out = currentOutput
        // Live map is only valid once at least one chunk has rendered; before that (e.g. just
        // loaded/seeked and still paused) it has no points and `toSource` would return 0, hiding the
        // resume position. Fall back to the session start + output until the map is populated.
        if trimEnabled, let snap = producer?.snapshot(), !snap.map.points.isEmpty {
            return min(max(0, snap.map.toSource(out)), sourceDuration)   // live map: absolute source
        }
        return min(sessionSourceStart + out, sourceDuration)             // source == file (or map empty)
    }

    /// Seconds of output audio buffered ahead of the playhead (diagnostics).
    var bufferedAheadSeconds: TimeInterval {
        guard let snap = producer?.snapshot() else { return 0 }
        return max(0, snap.scheduledOutput - currentOutput)
    }

    // MARK: Internals

    private func startDisplayLoop() {
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { break }
                self.onTick?()
                self.checkEnd()
                try? await Task.sleep(for: .milliseconds(250))
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
