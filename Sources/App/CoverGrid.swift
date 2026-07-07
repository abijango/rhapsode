import SwiftUI

/// Scrolling cover grid shared by the Audiobooks + E-books shelves.
///
/// On the regular size class (iPad / Mac) covers are a FIXED width (`DS.Shelf.coverWidthRegular`):
/// resizing the window only changes the number of columns, never the cover size. The column count is
/// computed from the live width and the grid is centered, so there's no left-clump / trailing gap.
/// On compact (iPhone) it falls back to the flexible adaptive grid (covers fill the narrow width).
struct CoverGrid<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @ViewBuilder var content: Content

    private let spacing = DS.Shelf.spacing
    private let pad = DS.Spacing.md

    var body: some View {
        if hSize == .regular {
            GeometryReader { geo in
                let w = DS.Shelf.coverWidthRegular
                let usable = max(w, geo.size.width - pad * 2)
                let n = max(1, Int((usable + spacing) / (w + spacing)))
                let contentW = CGFloat(n) * w + CGFloat(n - 1) * spacing
                ScrollView {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)          // Spacer-center the fixed-width grid, so it's
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: spacing), count: n),
                                  spacing: spacing) {
                            content
                        }
                        .frame(width: contentW)
                        Spacer(minLength: 0)          // …centered rather than left-clumped.
                    }
                    .padding(.vertical, pad)
                }
            }
        } else {
            ScrollView {
                LazyVGrid(columns: DS.Shelf.columns(regular: false), spacing: spacing) {
                    content
                }
                .padding(pad)
            }
        }
    }
}
