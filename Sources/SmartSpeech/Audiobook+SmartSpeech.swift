import Foundation
import SwiftData
import SmartSpeechKit

/// The authoritative on/off + tier decision for a single book.
enum SmartSpeechResolved: Equatable {
    case off
    case on(SmartSpeechSettings.Preset)
}

/// Sentinel stored in `Audiobook.smartSpeechTier` meaning "explicitly off for this book".
/// (`nil` = inherit global; a `Preset.rawValue` = force that profile.)
let smartSpeechOffValue = "off"

extension Audiobook {
    /// The tier this book *would* use if enabled — the per-book override if it names a profile,
    /// otherwise the global default. Used for display ("Use Global (More)") and as the render
    /// preset. Note: an "off" override has no tier of its own, so this falls back to the default.
    var effectiveSmartSpeechTier: SmartSpeechSettings.Preset {
        smartSpeechTier.flatMap(SmartSpeechSettings.Preset.init(rawValue:)) ?? SmartSpeechPreferences.defaultTier
    }

    /// The single source of truth for whether SmartSpeech is active for this book and at which tier.
    ///
    /// `smartSpeechTier` semantics (spec §9, agreed UX):
    ///   • `nil`              → inherit global: on at the global default tier iff globally enabled
    ///   • `"off"`            → off for this book, even when globally enabled
    ///   • a `Preset.rawValue`→ force that profile for this book, even when globally **disabled**
    ///
    /// DRM/undecodable books (`smartSpeechUnavailable`) are always off. All gating — render
    /// orchestration and trimmed-vs-original playback selection — flows through this.
    var resolvedSmartSpeech: SmartSpeechResolved {
        if smartSpeechUnavailable == true { return .off }
        switch smartSpeechTier {
        case nil:
            return SmartSpeechPreferences.isEnabled ? .on(SmartSpeechPreferences.defaultTier) : .off
        case smartSpeechOffValue:
            return .off
        case let raw?:
            if let preset = SmartSpeechSettings.Preset(rawValue: raw) { return .on(preset) }
            // Unknown value — fail safe to the global behaviour.
            return SmartSpeechPreferences.isEnabled ? .on(SmartSpeechPreferences.defaultTier) : .off
        }
    }

    /// Number of books that have actually accrued trimmed-playback savings — drives the global
    /// stat card's "across N audiobooks" line. Shared by the Settings view and the self-test.
    static func countWithSmartSpeechSavings(_ books: [Audiobook]) -> Int {
        books.filter { ($0.smartSpeechSavedSeconds ?? 0) > 0 }.count
    }
}
