import Foundation
import CadenceKit

/// Single source of truth for the user-facing feature name. Must **not** be "Smart Speed"
/// (Overcast trademark) — spec §0. Change the name here only.
enum CadenceBranding {
    static let featureName = "Cadence"
}

/// Global Cadence settings (not per-book), stored in `UserDefaults`.
///
/// Per spec §9 the feature has a **global on/off** plus a **global default tier** applied to
/// new books; the per-book tier override lives on `Audiobook.cadenceTier`. We reuse CadenceKit's
/// `CadenceSettings.Preset` as the tier type (Flag 7) so the app and the `cadence` CLI never drift.
enum CadencePreferences {
    // `UserDefaults.standard` is internally thread-safe but not `Sendable`; under strict
    // concurrency we reference it inline rather than holding it in static storage.
    private enum Key {
        static let enabled = "cadence.enabled"
        static let defaultTier = "cadence.defaultTier"
    }

    /// Master switch. **Opt-in** — off until the user turns it on, because rendering has a
    /// (one-time, background) cost and we don't want to surprise-process every existing book.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Key.enabled) }
    }

    /// Tier applied to books that have no explicit per-book override. Default `.default`.
    static var defaultTier: CadenceSettings.Preset {
        get { CadenceSettings.Preset(rawValue: UserDefaults.standard.string(forKey: Key.defaultTier) ?? "") ?? .default }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.defaultTier) }
    }
}
