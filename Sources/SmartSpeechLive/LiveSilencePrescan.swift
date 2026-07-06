import AVFoundation
import Foundation
import SmartSpeechKit

/// Live-only detection tuning. Kept separate from the shipped `SmartSpeechSettings` defaults so the
/// spike can be tuned without touching the pre-render feature.
enum LiveSmartSpeechTuning {
    /// Absolute silence ceiling for the LIVE path. The shipped default (−50 dBFS) is stricter than
    /// many real recordings' noise floors (compressed / loudness-normalized audiobooks often sit at
    /// −40…−48 dBFS), so it suppressed almost all trimming. −30 dBFS restores trimming for normal
    /// recordings; the global adaptive floor (Fix A) is what actually spares music, so this ceiling
    /// only ever acts as a backstop against genuinely loud continuous beds.
    static let silenceCeilingDb: Double = -30

    /// SmartSpeechSettings for the live path: tier preset with the relaxed live ceiling applied.
    static func settings(preset: SmartSpeechSettings.Preset) -> SmartSpeechSettings {
        var s = SmartSpeechSettings(preset: preset)
        s.absoluteSilenceCeilingDb = silenceCeilingDb
        return s
    }
}

/// EXPLORATION MODULE — live (on-the-fly) SmartSpeech. See `specs/realtime-cadence-exploration.md`
/// and the plan `~/.claude/plans/the-app-currently-uses-streamed-corbato.md`. Isolated from the
/// shipped pre-render SmartSpeech pipeline; nothing here touches `AudiobookPlayer`/`SmartSpeechRenderer`.
///
/// The hybrid "analyze-ahead" half: because a book is always fully downloaded before playback, we
/// run a cheap full-file analysis pass ONCE at load to learn the complete silence picture up front —
/// the projected total time saved and the region count — without rendering a trimmed file to disk.
/// The live splice (`LiveTrimProducer`) happens during playback. This is analysis only.
///
/// Reuses SmartSpeechKit verbatim (`AudioIO`, `SilenceAnalyzer`, `SilencePolicy`) and the app's existing
/// `SmartSpeechRenderer.chunkWindows` so the chunking matches the pre-render oracle exactly — which is
/// what makes the M0 assertion (prescan projection == `SmartSpeechRenderer` projection) meaningful.
struct LiveSilencePrescanResult: Sendable {
    let sourceDuration: TimeInterval
    /// Ideal seconds saved for the active tier: `Σ (D − target(D))` over detected regions. Matches
    /// `SmartSpeechRenderer.projectedSaved` / `TrimReport`'s ideal figure (actual rendered saving is a
    /// per-join crossfade delta less).
    let projectedSavedSeconds: TimeInterval
    let regionCount: Int
    /// Same projection for every tier (`Preset.rawValue` → seconds) from the shared decode/RMS pass.
    let projectedSavedByTier: [String: TimeInterval]
    /// Global (whole-file) adaptive noise floor / speech level. The live producer feeds `globalFloorDb`
    /// into per-chunk detection so the threshold is stable across chunk boundaries (Fix A).
    let globalFloorDb: Double
    let globalSpeechDb: Double

    var projectedSavedPercent: Double {
        sourceDuration > 0 ? projectedSavedSeconds / sourceDuration : 0
    }
}

enum LiveSilencePrescan {
    /// Chunk cap for the pre-scan. Large is fine — this pass is analysis-only (windowed RMS +
    /// percentiles + policy), which the de-risk measured at ~thousands× realtime.
    static let maxChunkSeconds: TimeInterval = 300

    /// Analyse a single fully-downloaded source file for the given tier. Decodes chunk-by-chunk so
    /// peak memory stays bounded regardless of book length; never keeps rendered audio.
    ///
    /// Runs off the main actor (it decodes and does DSP) — call from a detached task.
    static func analyze(url: URL,
                        cutPoints: [TimeInterval],
                        preset: SmartSpeechSettings.Preset) throws -> LiveSilencePrescanResult {
        let probe: AVAudioFile
        do { probe = try AVAudioFile(forReading: url) }
        catch { throw AudioIOError.undecodable(underlying: error) }
        let sampleRate = probe.processingFormat.sampleRate
        let sourceDuration = Double(probe.length) / sampleRate
        guard probe.length > 0 else {
            return .init(sourceDuration: 0, projectedSavedSeconds: 0, regionCount: 0,
                         projectedSavedByTier: [:], globalFloorDb: -160, globalSpeechDb: -160)
        }

        let windows = SmartSpeechRenderUtil.chunkWindows(cutPoints: cutPoints, totalDuration: sourceDuration,
                                                   maxChunkSeconds: maxChunkSeconds)

        // Pass 1: accumulate a whole-file loudness histogram → global adaptive floor/speech (Fix A).
        // A single global floor keeps the live producer's per-chunk detection stable, unlike the
        // jittery per-12s-chunk percentiles.
        var hist = LoudnessHistogram()
        for w in windows {
            try autoreleasepool {
                let buffer = try AudioIO.decode(url, startSeconds: w.start, durationSeconds: w.end - w.start,
                                                maxSeconds: maxChunkSeconds + 5)
                let mono = AudioIO.downmixToMono(buffer)
                let profile = SilenceAnalyzer.profile(monoSamples: mono, sampleRate: sampleRate)
                for db in profile.dbs { hist.add(db) }
            }
        }
        let globalFloorDb = hist.percentile(0.10)
        let globalSpeechDb = hist.percentile(0.90)

        // Pass 2: per-tier projection using the GLOBAL floor, so the projected number matches what
        // playback actually trims (the producer detects with the same global floor).
        var regionCount = 0
        var projectedSavedByTier: [String: TimeInterval] = [:]
        for w in windows {
            try autoreleasepool {
                let buffer = try AudioIO.decode(url, startSeconds: w.start, durationSeconds: w.end - w.start,
                                                maxSeconds: maxChunkSeconds + 5)
                let mono = AudioIO.downmixToMono(buffer)
                let profile = SilenceAnalyzer.profile(monoSamples: mono, sampleRate: sampleRate)
                for tierPreset in SmartSpeechSettings.Preset.allCases {
                    let tierSettings = LiveSmartSpeechTuning.settings(preset: tierPreset)
                    let regions = SilenceAnalyzer(settings: tierSettings)
                        .regions(from: profile, floorOverrideDb: globalFloorDb, speechOverrideDb: nil)
                    projectedSavedByTier[tierPreset.rawValue, default: 0] += projectedSaved(regions: regions, settings: tierSettings)
                    if tierPreset == preset { regionCount += regions.count }
                }
            }
        }

        return LiveSilencePrescanResult(
            sourceDuration: sourceDuration,
            projectedSavedSeconds: projectedSavedByTier[preset.rawValue] ?? 0,
            regionCount: regionCount,
            projectedSavedByTier: projectedSavedByTier,
            globalFloorDb: globalFloorDb,
            globalSpeechDb: globalSpeechDb)
    }

    /// Fixed-bin dB histogram (−160…0 dBFS, 0.5 dB bins) for computing whole-file percentiles in O(1)
    /// memory regardless of book length.
    private struct LoudnessHistogram {
        static let lo = -160.0, hi = 0.0, step = 0.5
        static let binCount = Int((hi - lo) / step) + 1
        private var bins = [Int](repeating: 0, count: binCount)
        private var total = 0

        mutating func add(_ db: Double) {
            let idx = min(max(0, Int((db - Self.lo) / Self.step)), Self.binCount - 1)
            bins[idx] += 1; total += 1
        }

        /// Value at percentile `p` (0…1); the low-p is the quiet cluster (noise floor).
        func percentile(_ p: Double) -> Double {
            guard total > 0 else { return Self.lo }
            let target = Int((Double(total - 1) * p).rounded())
            var cum = 0
            for (i, c) in bins.enumerated() {
                cum += c
                if cum > target { return Self.lo + (Double(i) + 0.5) * Self.step }
            }
            return Self.hi
        }
    }

    /// Ideal saving for one tier: `Σ (D − target(D))`. Identical formula to
    /// `SmartSpeechRenderer.projectedSaved` (kept private there) — reproduced so the spike stays isolated.
    private static func projectedSaved(regions: [SilenceRegion], settings: SmartSpeechSettings) -> TimeInterval {
        regions.reduce(0.0) { acc, region in
            acc + (region.duration - SilencePolicy.target(forSilenceDuration: region.duration, settings: settings))
        }
    }
}
