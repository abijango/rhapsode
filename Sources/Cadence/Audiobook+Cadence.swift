import Foundation
import CadenceKit

extension Audiobook {
    /// The effective Cadence tier for this book: the per-book override (`cadenceTier`) if set,
    /// otherwise the global default. Persisted positions/chapters are tier-independent
    /// (source-domain), so changing this only triggers a re-render (spec §7.2 / §9).
    var effectiveCadenceTier: CadenceSettings.Preset {
        cadenceTier.flatMap(CadenceSettings.Preset.init(rawValue:)) ?? CadencePreferences.defaultTier
    }
}
