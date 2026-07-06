import Accelerate
import Foundation

/// A stretch of source audio quiet enough to trim, expressed in source time.
/// Boundaries are already edge-guarded (shrunk inward) by the analyzer.
public struct SilenceRegion: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public var duration: TimeInterval { end - start }

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// Result of analysing one section: the silence regions plus the diagnostics
/// (noise floor, sample rate) that explain how they were found.
public struct AnalysisResult: Sendable {
    public let regions: [SilenceRegion]
    public let noiseFloorDb: Double
    public let sampleRate: Double
}

/// The **tier-independent** loudness profile of one section: the windowed dB envelope plus the
/// adaptive floor/speech levels. Computing this (the vDSP RMS pass + the two percentiles) is the
/// expensive part of analysis; turning it into regions for a given `SmartSpeechSettings` is cheap.
/// Callers that need several tiers (the renderer's per-tier savings projection) compute this ONCE
/// with `SilenceAnalyzer.profile(...)` and call `regions(from:)` per tier — avoiding redundant RMS.
public struct LoudnessProfile: Sendable {
    public let dbs: [Double]
    public let hop: Int
    public let noiseFloorDb: Double
    public let speechLevelDb: Double
    public let sampleRate: Double
}

/// Detects trimmable silences in mono PCM. Pure and audio-hardware-free: it takes a
/// `[Float]` and a sample rate, so it is driven entirely by synthetic PCM in tests.
/// Implements the pipeline in `cadence-feature-spec.md` §4.
public struct SilenceAnalyzer {
    public let settings: SmartSpeechSettings

    // Hysteresis / bridging are implementation details, not user-facing knobs.
    static let windowMs = 20.0
    static let hopMs = 10.0
    static let attackMs = 20.0    // consecutive quiet to *open* a region (rejects mid-speech blips)
    static let releaseMs = 20.0   // consecutive loud to *close* a region
    static let bridgeMs = 40.0    // merge regions separated by less than this (flutter)
    static let noiseFloorPercentile = 0.10
    static let speechLevelPercentile = 0.90
    static let minSeparationDb = 3.0   // keep the threshold this far below the speech level
    static let silenceFloorDb = -160.0

    public init(settings: SmartSpeechSettings) {
        self.settings = settings
    }

    /// Analyse mono float32 PCM. Returns edge-guarded silence regions in source time.
    /// Equivalent to `regions(from: Self.profile(...))` — kept as the single-shot entry point.
    public func analyze(monoSamples: [Float], sampleRate: Double) -> AnalysisResult {
        let profile = Self.profile(monoSamples: monoSamples, sampleRate: sampleRate)
        return AnalysisResult(regions: regions(from: profile),
                              noiseFloorDb: profile.noiseFloorDb, sampleRate: sampleRate)
    }

    /// Compute the tier-independent loudness profile (the expensive windowed-RMS + percentile pass).
    /// `static` because it does NOT depend on `settings` — only on the fixed window/hop constants —
    /// which is exactly why it can be shared across tiers.
    public static func profile(monoSamples: [Float], sampleRate: Double) -> LoudnessProfile {
        let windowSize = max(1, Int((windowMs / 1000.0 * sampleRate).rounded()))
        let hop = max(1, Int((hopMs / 1000.0 * sampleRate).rounded()))
        let dbs = windowedRMSdB(monoSamples, windowSize: windowSize, hop: hop)
        // When empty, mirror the previous behaviour: silence-floor diagnostics, no regions.
        let noiseFloor = dbs.isEmpty ? silenceFloorDb : percentile(dbs, noiseFloorPercentile)
        let speechLevel = dbs.isEmpty ? silenceFloorDb : percentile(dbs, speechLevelPercentile)
        return LoudnessProfile(dbs: dbs, hop: hop, noiseFloorDb: noiseFloor,
                               speechLevelDb: speechLevel, sampleRate: sampleRate)
    }

    /// Derive edge-guarded silence regions for THIS analyzer's `settings` from a precomputed
    /// profile. Cheap (threshold compare + hysteresis + edge-guard); safe to call per tier.
    public func regions(from profile: LoudnessProfile) -> [SilenceRegion] {
        regions(from: profile, floorOverrideDb: nil, speechOverrideDb: nil)
    }

    /// As `regions(from:)`, but the live (on-the-fly) engine can inject an external floor/speech
    /// (e.g. a global, whole-file profile) in place of this chunk-local profile's percentiles. The
    /// live engine analyses short streaming chunks whose local percentiles jitter across chunk
    /// boundaries; a stable global floor makes detection deterministic regardless of where a chunk
    /// falls (Fix A). Both `nil` ⇒ **byte-identical** to `regions(from:)`, so the shipped pre-render
    /// path and `analyzerVersion` are unchanged. The absolute-silence ceiling (Fix B) still applies
    /// via `settings.absoluteSilenceCeilingDb`.
    public func regions(from profile: LoudnessProfile,
                        floorOverrideDb: Double?,
                        speechOverrideDb: Double?) -> [SilenceRegion] {
        guard !profile.dbs.isEmpty else { return [] }

        let floorDb = floorOverrideDb ?? profile.noiseFloorDb
        let speechDb = speechOverrideDb ?? profile.speechLevelDb
        // Clamp the threshold below the speech level: a section with no genuine quiet
        // cluster (floor ≈ speech, e.g. continuous narration) must not flag everything as
        // silence. In the normal case (floor far below speech) this leaves floor+margin intact.
        let adaptive = min(floorDb + settings.thresholdMarginDb,
                           speechDb - Self.minSeparationDb)
        // Clamp by the absolute silence ceiling so a loud continuous bed (music/ambience) — whose
        // adaptive floor is high — is never treated as trimmable. This only ever tightens the
        // threshold; clean narration already sits below the ceiling and is unaffected.
        let threshold = min(adaptive, settings.absoluteSilenceCeilingDb)
        let silent = profile.dbs.map { $0 < threshold }

        func windows(forMs ms: Double) -> Int {
            max(1, Int((ms / 1000.0 * profile.sampleRate / Double(profile.hop)).rounded()))
        }
        let windowRanges = Self.detectRegions(
            silent: silent,
            attackWindows: windows(forMs: Self.attackMs),
            releaseWindows: windows(forMs: Self.releaseMs),
            bridgeWindows: windows(forMs: Self.bridgeMs))

        // Window index → source time. Window w spans samples [w*hop, w*hop+windowSize);
        // we anchor region boundaries to hop starts (within ±1 window of tolerance).
        let hopSeconds = Double(profile.hop) / profile.sampleRate
        let guardSeconds = settings.edgeGuardMs / 1000.0
        var regions: [SilenceRegion] = []
        for (startWindow, endWindow) in windowRanges {
            let start = Double(startWindow) * hopSeconds + guardSeconds
            let end = Double(endWindow) * hopSeconds - guardSeconds
            // Discard is applied to the *edge-guarded* duration (spec §4.4 order).
            guard end - start >= settings.minSilenceDuration else { continue }
            regions.append(SilenceRegion(start: start, end: end))
        }
        return regions
    }

    // MARK: - Pure stages (internal for direct unit testing)

    /// Per-window RMS in dBFS (reference 1.0). 20 ms window, 10 ms hop by default.
    static func windowedRMSdB(_ samples: [Float], windowSize: Int, hop: Int) -> [Double] {
        guard windowSize > 0, hop > 0, samples.count >= windowSize else { return [] }
        let count = (samples.count - windowSize) / hop + 1
        var out = [Double]()
        out.reserveCapacity(count)
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for w in 0..<count {
                var rms: Float = 0
                vDSP_rmsqv(base + w * hop, 1, &rms, vDSP_Length(windowSize))
                out.append(rms > 0 ? 20.0 * log10(Double(rms)) : silenceFloorDb)
            }
        }
        return out
    }

    /// Low-percentile of the windowed-dB distribution — the quiet cluster, i.e. the
    /// adaptive noise floor. Per section, which is what adapts to quiet narrators.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return silenceFloorDb }
        let sorted = values.sorted()
        let idx = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[idx]
    }

    /// Noise-gate region detection with attack/release hysteresis + bridging.
    /// Returns half-open window-index ranges `[start, end)` (end = first loud window).
    static func detectRegions(silent: [Bool],
                              attackWindows: Int,
                              releaseWindows: Int,
                              bridgeWindows: Int) -> [(Int, Int)] {
        var raw: [(Int, Int)] = []
        var openStart: Int? = nil
        var silentRun = 0, silentRunStart = 0
        var loudRun = 0, loudRunStart = 0

        for (i, isSilent) in silent.enumerated() {
            if isSilent {
                if silentRun == 0 { silentRunStart = i }
                silentRun += 1
                loudRun = 0
                if openStart == nil, silentRun >= attackWindows { openStart = silentRunStart }
            } else {
                if loudRun == 0 { loudRunStart = i }
                loudRun += 1
                silentRun = 0
                if let s = openStart, loudRun >= releaseWindows {
                    raw.append((s, loudRunStart))
                    openStart = nil
                }
            }
        }
        if let s = openStart { raw.append((s, silent.count)) }

        // Bridge regions separated by a sub-threshold gap so flutter doesn't fragment them.
        var bridged: [(Int, Int)] = []
        for r in raw {
            if let last = bridged.last, r.0 - last.1 < bridgeWindows {
                bridged[bridged.count - 1].1 = r.1
            } else {
                bridged.append(r)
            }
        }
        return bridged
    }
}
