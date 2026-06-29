import Foundation
import CadenceKit

/// The authoritative on/off + tier decision for a single book.
enum CadenceResolved: Equatable {
    case off
    case on(CadenceSettings.Preset)
}

/// Sentinel stored in `Audiobook.cadenceTier` meaning "explicitly off for this book".
/// (`nil` = inherit global; a `Preset.rawValue` = force that profile.)
let cadenceOffValue = "off"

extension Audiobook {
    /// The tier this book *would* use if enabled — the per-book override if it names a profile,
    /// otherwise the global default. Used for display ("Use Global (More)") and as the render
    /// preset. Note: an "off" override has no tier of its own, so this falls back to the default.
    var effectiveCadenceTier: CadenceSettings.Preset {
        cadenceTier.flatMap(CadenceSettings.Preset.init(rawValue:)) ?? CadencePreferences.defaultTier
    }

    /// The single source of truth for whether Cadence is active for this book and at which tier.
    ///
    /// `cadenceTier` semantics (spec §9, agreed UX):
    ///   • `nil`              → inherit global: on at the global default tier iff globally enabled
    ///   • `"off"`            → off for this book, even when globally enabled
    ///   • a `Preset.rawValue`→ force that profile for this book, even when globally **disabled**
    ///
    /// DRM/undecodable books (`cadenceUnavailable`) are always off. All gating — render
    /// orchestration and trimmed-vs-original playback selection — flows through this.
    var resolvedCadence: CadenceResolved {
        if cadenceUnavailable == true { return .off }
        switch cadenceTier {
        case nil:
            return CadencePreferences.isEnabled ? .on(CadencePreferences.defaultTier) : .off
        case cadenceOffValue:
            return .off
        case let raw?:
            if let preset = CadenceSettings.Preset(rawValue: raw) { return .on(preset) }
            // Unknown value — fail safe to the global behaviour.
            return CadencePreferences.isEnabled ? .on(CadencePreferences.defaultTier) : .off
        }
    }

    /// Number of books that have actually accrued trimmed-playback savings — drives the global
    /// stat card's "across N audiobooks" line. Shared by the Settings view and the self-test.
    static func countWithCadenceSavings(_ books: [Audiobook]) -> Int {
        books.filter { ($0.cadenceSavedSeconds ?? 0) > 0 }.count
    }
}
