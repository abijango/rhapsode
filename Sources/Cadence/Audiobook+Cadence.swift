import Foundation
import SwiftData
import CadenceKit

/// Aggregated, per-tier projected Cadence savings for one book, summed across its files.
/// Drives the per-tier comparison in the per-book settings sheet.
struct CadenceProjectedSavings {
    /// Projected seconds saved per tier (`Preset.rawValue` → seconds), summed across the book's
    /// rendered files. Empty until at least one file has been rendered with projections.
    let savedByTier: [String: TimeInterval]
    /// Sum of original (untrimmed) durations across the rendered files (≈ `book.totalDuration`).
    let originalDuration: TimeInterval

    /// Projected seconds saved for a specific tier (0 if unknown).
    func saved(for preset: CadenceSettings.Preset) -> TimeInterval { savedByTier[preset.rawValue] ?? 0 }
    /// Whether any projection data is available yet.
    var hasData: Bool { !savedByTier.isEmpty }
}

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

    /// Aggregate the per-tier projected savings (and total original runtime) for this book by
    /// summing its `TrimmedRendition` rows (one per file). Each row carries projections for ALL
    /// tiers, so the sum is exact for whatever files have been rendered; a multi-file book that is
    /// only partly rendered yields a partial (growing) sum. Legacy rows without projections
    /// contribute their original duration but no per-tier breakdown.
    static func projectedSavings(forBookID id: UUID, context: ModelContext) -> CadenceProjectedSavings {
        let rows = ((try? context.fetch(FetchDescriptor<TrimmedRendition>())) ?? [])
            .filter { $0.bookID == id }
        var byTier: [String: TimeInterval] = [:]
        var original: TimeInterval = 0
        for row in rows {
            original += row.originalDuration
            for (tier, seconds) in row.projectedSavedByTier { byTier[tier, default: 0] += seconds }
        }
        return CadenceProjectedSavings(savedByTier: byTier, originalDuration: original)
    }

    /// Per-book render summary for the status screen: actual rendered seconds saved, wall-clock
    /// render time, and whether any rendition exists — summed across the book's files.
    static func renderSummary(forBookID id: UUID, context: ModelContext)
        -> (savedSeconds: TimeInterval, renderSeconds: TimeInterval, hasRendition: Bool) {
        let rows = ((try? context.fetch(FetchDescriptor<TrimmedRendition>())) ?? [])
            .filter { $0.bookID == id }
        let saved = rows.reduce(0) { $0 + $1.savedSeconds }
        let render = rows.reduce(0) { $0 + ($1.renderDurationSeconds ?? 0) }
        return (saved, render, !rows.isEmpty)
    }
}
