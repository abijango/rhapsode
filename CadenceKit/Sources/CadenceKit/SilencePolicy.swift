import Foundation

/// Pure D→target mapping: given a silence of source duration `D`, how long should
/// the trimmed residual be? This is the whole of the "proportional aggressiveness"
/// behaviour and is exhaustively unit-tested. See `cadence-feature-spec.md` §6.
public enum SilencePolicy {
    /// Target residual duration for a silence of source duration `D`.
    ///
    /// - `D < minSilenceDuration` → `D` (untouched).
    /// - otherwise → `clamp(minKeptSilence + (D - minSilenceDuration) * residualSlope,
    ///                       lower: minKeptSilence, upper: D)`.
    ///
    /// Properties guaranteed (and tested): monotonic non-decreasing in `D`,
    /// `target ≤ D`, and `target ≥ minKeptSilence` once a silence is eligible.
    public static func target(forSilenceDuration D: TimeInterval,
                              settings: CadenceSettings) -> TimeInterval {
        guard D >= settings.minSilenceDuration else { return D }
        let proportional = settings.minKeptSilence
            + (D - settings.minSilenceDuration) * settings.residualSlope
        return min(max(proportional, settings.minKeptSilence), D)
    }
}
