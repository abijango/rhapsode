import AVFoundation
import Foundation
import SmartSpeechKit

/// Live-only detection tuning. Kept separate from the `SmartSpeechSettings` defaults so the
/// ceiling can be relaxed for real recordings without changing CadenceLab preset values.
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

/// Analyze-ahead pass for live SmartSpeech. Because a book is fully downloaded before playback, a
/// cheap full-file analysis runs once at load for the silence picture, projected time saved, and
/// region list. No trimmed file is written. The live splice (`LiveTrimProducer`) happens during
/// playback. This is analysis only.
///
/// Reuses SmartSpeechKit (`AudioIO`, `SilenceAnalyzer`, `SilencePolicy`) and
/// `SmartSpeechRenderUtil.chunkWindows` so prescan windows match the live producer.
struct LiveSilencePrescanResult: Sendable {
    let sourceDuration: TimeInterval
    /// Ideal seconds saved for the active tier: `Σ (D − target(D))` over detected regions. Matches
    /// `TrimReport`'s ideal figure (actual splice saving is a per-join crossfade delta less).
    let projectedSavedSeconds: TimeInterval
    let regionCount: Int
    /// Active-tier projection only (key = `preset.rawValue`).
    let projectedSavedByTier: [String: TimeInterval]
    /// Global (whole-file) adaptive noise floor / speech level. The live producer feeds `globalFloorDb`
    /// into per-chunk detection so the threshold is stable across chunk boundaries (Fix A).
    let globalFloorDb: Double
    let globalSpeechDb: Double
    /// Silence regions for the active preset in absolute source time. Merged across decode-window seams
    /// so the live producer can skip per-chunk RMS when this list is supplied.
    let regions: [SilenceRegion]

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
                         projectedSavedByTier: [:], globalFloorDb: -160, globalSpeechDb: -160,
                         regions: [])
        }

        let windows = SmartSpeechRenderUtil.chunkWindows(cutPoints: cutPoints, totalDuration: sourceDuration,
                                                   maxChunkSeconds: maxChunkSeconds)

        // Single decode pass: accumulate a whole-file loudness histogram and retain each window's
        // tier-independent profile so tier projections and region lists reuse the same RMS work.
        var hist = LoudnessHistogram()
        var windowProfiles: [(start: TimeInterval, profile: LoudnessProfile)] = []
        windowProfiles.reserveCapacity(windows.count)
        for w in windows {
            try autoreleasepool {
                let buffer = try AudioIO.decode(url, startSeconds: w.start, durationSeconds: w.end - w.start,
                                                maxSeconds: maxChunkSeconds + 5)
                let mono = AudioIO.downmixToMono(buffer)
                let profile = SilenceAnalyzer.profile(monoSamples: mono, sampleRate: sampleRate)
                for db in profile.dbs { hist.add(db) }
                windowProfiles.append((w.start, profile))
            }
        }
        let globalFloorDb = hist.percentile(0.10)
        let globalSpeechDb = hist.percentile(0.90)

        var projectedSavedByTier: [String: TimeInterval] = [:]
        var presetRegions: [SilenceRegion] = []
        let tierSettings = LiveSmartSpeechTuning.settings(preset: preset)
        for (windowStart, profile) in windowProfiles {
            let regions = SilenceAnalyzer(settings: tierSettings)
                .regions(from: profile, floorOverrideDb: globalFloorDb, speechOverrideDb: nil)
            projectedSavedByTier[preset.rawValue, default: 0] += projectedSaved(regions: regions, settings: tierSettings)
            presetRegions += regions.map {
                SilenceRegion(start: windowStart + $0.start, end: windowStart + $0.end)
            }
        }
        let mergedRegions = mergeRegionsAcrossSeams(presetRegions)

        return LiveSilencePrescanResult(
            sourceDuration: sourceDuration,
            projectedSavedSeconds: projectedSavedByTier[preset.rawValue] ?? 0,
            regionCount: mergedRegions.count,
            projectedSavedByTier: projectedSavedByTier,
            globalFloorDb: globalFloorDb,
            globalSpeechDb: globalSpeechDb,
            regions: mergedRegions)
    }

    /// Merge regions that overlap or are separated by less than the analyzer's bridge gap so silences
    /// spanning decode-window seams are not fragmented.
    private static func mergeRegionsAcrossSeams(_ regions: [SilenceRegion]) -> [SilenceRegion] {
        guard !regions.isEmpty else { return [] }
        let bridgeSeconds = 40.0 / 1000.0   // matches `SilenceAnalyzer.bridgeMs`
        let sorted = regions.sorted { $0.start < $1.start }
        var merged: [SilenceRegion] = [sorted[0]]
        for r in sorted.dropFirst() {
            var last = merged[merged.count - 1]
            if r.start <= last.end + bridgeSeconds {
                last = SilenceRegion(start: last.start, end: max(last.end, r.end))
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged
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

    /// Ideal saving for one tier: `Σ (D − target(D))`.
    private static func projectedSaved(regions: [SilenceRegion], settings: SmartSpeechSettings) -> TimeInterval {
        regions.reduce(0.0) { acc, region in
            acc + (region.duration - SilencePolicy.target(forSilenceDuration: region.duration, settings: settings))
        }
    }
}
