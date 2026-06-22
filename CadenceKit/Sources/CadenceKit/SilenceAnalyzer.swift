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

/// Detects trimmable silences in mono PCM. Pure and audio-hardware-free: it takes a
/// `[Float]` and a sample rate, so it is driven entirely by synthetic PCM in tests.
/// Implements the pipeline in `cadence-feature-spec.md` §4.
public struct SilenceAnalyzer {
    public let settings: CadenceSettings

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

    public init(settings: CadenceSettings) {
        self.settings = settings
    }

    /// Analyse mono float32 PCM. Returns edge-guarded silence regions in source time.
    public func analyze(monoSamples: [Float], sampleRate: Double) -> AnalysisResult {
        let windowSize = max(1, Int((Self.windowMs / 1000.0 * sampleRate).rounded()))
        let hop = max(1, Int((Self.hopMs / 1000.0 * sampleRate).rounded()))

        let dbs = Self.windowedRMSdB(monoSamples, windowSize: windowSize, hop: hop)
        guard !dbs.isEmpty else {
            return AnalysisResult(regions: [], noiseFloorDb: Self.silenceFloorDb, sampleRate: sampleRate)
        }

        let noiseFloor = Self.percentile(dbs, Self.noiseFloorPercentile)
        let speechLevel = Self.percentile(dbs, Self.speechLevelPercentile)
        // Clamp the threshold below the speech level: a section with no genuine quiet
        // cluster (floor ≈ speech, e.g. continuous narration) must not flag everything as
        // silence. In the normal case (floor far below speech) this leaves floor+margin intact.
        let threshold = min(noiseFloor + settings.thresholdMarginDb, speechLevel - Self.minSeparationDb)
        let silent = dbs.map { $0 < threshold }

        func windows(forMs ms: Double) -> Int {
            max(1, Int((ms / 1000.0 * sampleRate / Double(hop)).rounded()))
        }
        let windowRanges = Self.detectRegions(
            silent: silent,
            attackWindows: windows(forMs: Self.attackMs),
            releaseWindows: windows(forMs: Self.releaseMs),
            bridgeWindows: windows(forMs: Self.bridgeMs))

        // Window index → source time. Window w spans samples [w*hop, w*hop+windowSize);
        // we anchor region boundaries to hop starts (within ±1 window of tolerance).
        let hopSeconds = Double(hop) / sampleRate
        let guardSeconds = settings.edgeGuardMs / 1000.0
        var regions: [SilenceRegion] = []
        for (startWindow, endWindow) in windowRanges {
            let start = Double(startWindow) * hopSeconds + guardSeconds
            let end = Double(endWindow) * hopSeconds - guardSeconds
            // Discard is applied to the *edge-guarded* duration (spec §4.4 order).
            guard end - start >= settings.minSilenceDuration else { continue }
            regions.append(SilenceRegion(start: start, end: end))
        }

        return AnalysisResult(regions: regions, noiseFloorDb: noiseFloor, sampleRate: sampleRate)
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
