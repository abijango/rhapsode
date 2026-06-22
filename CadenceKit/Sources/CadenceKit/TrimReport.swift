import Foundation

/// Savings summary for one trimmed section. `Codable` so the CLI can emit it as JSON.
///
/// `trimmedDuration` is **measured from the rendered buffer** and is the source of truth —
/// it is slightly shorter than `Σ target` because each crossfade overlaps its join.
/// `meanRegionSaving` is derived from the policy and is therefore an *ideal, pre-splice*
/// figure; the CLI labels it as such so the small gap doesn't read as a bug.
public struct TrimReport: Codable, Sendable {
    public let originalDuration: TimeInterval
    public let trimmedDuration: TimeInterval
    public let savedSeconds: TimeInterval
    public let savedPercent: Double
    public let regionCount: Int
    public let meanRegionSaving: TimeInterval   // ideal (pre-splice): mean of (D − target)
    public let noiseFloorDb: Double
    public let sampleRate: Double
    public let settings: CadenceSettings

    public init(originalDuration: TimeInterval,
                trimmedDuration: TimeInterval,
                regions: [SilenceRegion],
                settings: CadenceSettings,
                noiseFloorDb: Double,
                sampleRate: Double) {
        self.originalDuration = originalDuration
        self.trimmedDuration = trimmedDuration
        let saved = max(0, originalDuration - trimmedDuration)
        self.savedSeconds = saved
        self.savedPercent = originalDuration > 0 ? saved / originalDuration * 100 : 0
        self.regionCount = regions.count
        let idealSaving = regions.reduce(0.0) { acc, region in
            acc + (region.duration - SilencePolicy.target(forSilenceDuration: region.duration, settings: settings))
        }
        self.meanRegionSaving = regions.isEmpty ? 0 : idealSaving / Double(regions.count)
        self.noiseFloorDb = noiseFloorDb
        self.sampleRate = sampleRate
        self.settings = settings
    }
}
