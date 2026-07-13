import SwiftUI
import UIKit

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
        /// Legacy minimum — kept for tests; compact shelves now use `compactCoverWidth`.
        static let minCoverWidth: CGFloat = 120
        /// FIXED cover width on iPad (regular size class). Resizing only changes column count.
        static let coverWidthPad: CGFloat = 320
        /// FIXED cover width on Mac Catalyst — larger canvas, bigger art.
        static let coverWidthMac: CGFloat = 420
        /// Regular-size-class cover width for the current platform.
        static var coverWidthRegular: CGFloat {
            #if targetEnvironment(macCatalyst)
            coverWidthMac
            #else
            coverWidthPad
            #endif
        }
        /// Default e-book cover (portrait). Used as placeholder aspect when no image yet.
        static let coverAspect: CGFloat = 2.0 / 3.0 // width / height
        /// Default audiobook cover (Audible / square art).
        static let audiobookCoverAspect: CGFloat = 1.0
        /// Clamp live image aspect so one ultra-wide/tall file cannot break the grid.
        static let coverAspectMin: CGFloat = 0.55   // taller than ~9:16
        static let coverAspectMax: CGFloat = 1.15   // slightly wider than square

        /// Placeholder aspect before art loads (or when missing).
        static func placeholderCoverAspect(for kind: FolderKind) -> CGFloat {
            kind == .audiobooks ? audiobookCoverAspect : coverAspect
        }

        /// Prefer the image’s real width/height so the tile box matches the art (no letterbox).
        static func coverAspect(for image: UIImage?, kind: FolderKind) -> CGFloat {
            guard let image else { return placeholderCoverAspect(for: kind) }
            let w = image.size.width
            let h = image.size.height
            guard w > 1, h > 1 else { return placeholderCoverAspect(for: kind) }
            let raw = w / h
            return min(max(raw, coverAspectMin), coverAspectMax)
        }

        static let spacing: CGFloat = Spacing.md
        /// Compact shelves (iPhone, iPad detail column) always use two wide columns when space
        /// allows — the old adaptive minimum let three skinny columns fit on wider phones.
        static let compactColumnCount = 2
        /// Below this usable inner width, drop to one column (very narrow split / landscape).
        static let compactSingleColumnThreshold: CGFloat = 260

        /// Column count for a compact shelf given the inner width (after horizontal padding).
        static func compactColumnCount(forUsableWidth usable: CGFloat) -> Int {
            usable >= compactSingleColumnThreshold ? compactColumnCount : 1
        }

        /// Cover width that fills the available compact width with `compactColumnCount` columns.
        static func compactCoverWidth(forUsableWidth usable: CGFloat) -> CGFloat {
            let n = CGFloat(compactColumnCount(forUsableWidth: usable))
            guard n > 0, usable > 0 else { return minCoverWidth }
            return (usable - (n - 1) * spacing) / n
        }

        /// Adaptive grid columns for the shelves. On regular, the item is a FIXED width so covers
        /// stay a stable size as the window resizes (only column count / gaps change). Shared by the
        /// Audiobooks + E-books shelves. Compact uses `compactCoverWidth` via `CoverGrid`.
        static func columns(regular: Bool) -> [GridItem] {
            regular
                ? [GridItem(.adaptive(minimum: coverWidthRegular, maximum: coverWidthRegular), spacing: spacing)]
                : [GridItem(.adaptive(minimum: minCoverWidth), spacing: spacing)]
        }
    }

    /// Semantic colors layered on the system palette (Liquid-Glass friendly).
    enum Palette {
        static let accent = Color.accentColor
        static let shelfBackground = Color(.systemGroupedBackground)
        static let coverPlaceholder = Color(.secondarySystemFill)

        /// "Reclaimed" palette (Ink & Mint) for the redesigned player and Nerd Stats. Trait-adaptive:
        /// dark values on a dark scheme, light values on a light scheme, so the global Appearance
        /// toggle applies here too. `mint` is the brand accent = reclaimed/saved time (deepened on
        /// light for contrast). Overlay tokens (hairline/fill/track) flip white↔black by scheme.
        enum Reclaim {
            static let mint       = Color.adaptive(light: 0x0FA378, dark: 0x35D6A4)   // accent / fills
            static let mintBright = Color.adaptive(light: 0x0C946D, dark: 0x5FE3BD)   // hero numbers
            static let bg1        = Color.adaptive(light: 0xF3F7F4, dark: 0x0E1512)   // gradient top
            static let bg2        = Color.adaptive(light: 0xE9EFEB, dark: 0x05100C)   // gradient bottom
            static let surface    = Color.adaptive(light: 0xFFFFFF, dark: 0x141B18)   // panels/sheets
            static let text       = Color.adaptive(light: 0x15201B, dark: 0xEAF2EE)
            static let muted      = Color.adaptive(light: 0x6B7772, dark: 0x8A9A93)
            static let onMint     = Color(hex: 0x06120D)                              // ink on mint fills (both schemes)
            static let knob       = Color.adaptive(light: 0x1B2621, dark: 0xFFFFFF)   // scrubber knob
            static let hairline   = Color.adaptiveOverlay(light: 0.10, dark: 0.09)    // dividers
            static let fill       = Color.adaptiveOverlay(light: 0.05, dark: 0.06)    // card/dock backgrounds
            static let stroke     = Color.adaptiveOverlay(light: 0.10, dark: 0.10)    // card/dock borders
            static let track      = Color.adaptiveOverlay(light: 0.12, dark: 0.14)    // progress/scrubber track
        }
    }
}

extension Color {
    /// 0xRRGGBB literal → Color (opaque). Keeps the "Reclaimed" hex tokens readable.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Trait-adaptive opaque color from two hex literals (resolves per light/dark scheme).
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// Trait-adaptive translucent overlay: white at `dark` alpha on a dark scheme, black at `light`
    /// alpha on a light scheme. For hairlines/fills/tracks that must read on either background.
    static func adaptiveOverlay(light: Double, dark: Double) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: dark)
                : UIColor(white: 0, alpha: light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue:  CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
