import SwiftUI

/// Lightweight design system: shared spacing, shelf metrics, and semantic colors.
/// Intentionally small for Phase 0 — expanded as the UI lands in later phases.
enum DS {

    /// 8-pt spacing scale.
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// Corner radii.
    enum Radius {
        static let cover: CGFloat = 8
        static let card: CGFloat = 12
    }

    /// Library shelf grid metrics.
    enum Shelf {
        /// Minimum cover width; the grid flows as many columns as fit.
        static let minCoverWidth: CGFloat = 120
        static let coverAspect: CGFloat = 2.0 / 3.0 // width / height
        static let spacing: CGFloat = Spacing.md
    }

    /// Semantic colors layered on the system palette (Liquid-Glass friendly).
    enum Palette {
        static let accent = Color.accentColor
        static let shelfBackground = Color(.systemGroupedBackground)
        static let coverPlaceholder = Color(.secondarySystemFill)
    }
}
