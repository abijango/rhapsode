import Foundation

/// The five (plus two splice) tunable parameters that control silence trimming.
///
/// These transfer verbatim into the production app; the values that survive the
/// listening A/B in the harness become the production defaults. See
/// `cadence-feature-spec.md` §6 and `cadence-derisk-harness-spec.md` §3.
public struct CadenceSettings: Equatable, Codable, Sendable {
    /// Silences shorter than this are left completely untouched — they are the
    /// inter-word / sentence rhythm, not dead air. (Rule 3.)
    public var minSilenceDuration: TimeInterval

    /// A trimmed silence is never collapsed below this floor, so the ear still
    /// registers a pause. (Rule 2.)
    public var minKeptSilence: TimeInterval

    /// Fraction of the *excess* silence (beyond `minSilenceDuration`) that is kept.
    /// Small slope ⇒ long dead gaps collapse hard, short pauses barely move. (Rule 5.)
    public var residualSlope: Double

    /// A window counts as silence when its level sits this many dB above the
    /// per-section adaptive noise floor. Relative, never absolute. (Rule 1.)
    public var thresholdMarginDb: Double

    /// Each detected region is shrunk inward by this many milliseconds on both
    /// sides, protecting word tails, breaths and plosive onsets. (Rule 4.)
    public var edgeGuardMs: Double

    /// Equal-power crossfade length applied at every splice so joins never click. (Rule 4.)
    public var crossfadeMs: Double

    public init(
        minSilenceDuration: TimeInterval = 0.28,
        minKeptSilence: TimeInterval = 0.18,
        residualSlope: Double = 0.12,
        thresholdMarginDb: Double = 8.0,
        edgeGuardMs: Double = 40,
        crossfadeMs: Double = 15
    ) {
        self.minSilenceDuration = minSilenceDuration
        self.minKeptSilence = minKeptSilence
        self.residualSlope = residualSlope
        self.thresholdMarginDb = thresholdMarginDb
        self.edgeGuardMs = edgeGuardMs
        self.crossfadeMs = crossfadeMs
    }
}
