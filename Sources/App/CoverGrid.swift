import SwiftUI

/// Scrolling cover grid shared by the Audiobooks + E-books shelves.
///
/// On the regular size class (iPad / Mac) covers are a FIXED platform width (`DS.Shelf.coverWidthRegular` —
/// larger on Mac Catalyst than iPad):
/// resizing the window only changes the number of columns, never the cover size. The column count is
/// computed from the live width and the grid is centered, so there's no left-clump / trailing gap.
/// On compact (iPhone / iPad detail column) it uses two fixed-width columns that grow to fill
/// the available width — wider than the old adaptive minimum that squeezed in three columns.
struct CoverGrid<Header: View, Content: View>: View {
    @Environment(\.horizontalSizeClass) private var hSize
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content

    private let spacing = DS.Shelf.spacing
    private let pad = DS.Spacing.md

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        if hSize == .regular {
            GeometryReader { geo in
                let w = DS.Shelf.coverWidthRegular
                let usable = max(w, geo.size.width - pad * 2)
                let n = max(1, Int((usable + spacing) / (w + spacing)))
                let contentW = CGFloat(n) * w + CGFloat(n - 1) * spacing
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(w), spacing: spacing), count: n),
                                      spacing: spacing) {
                                content
                            }
                            .frame(width: contentW)
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.vertical, pad)
                }
            }
        } else {
            GeometryReader { geo in
                let usable = max(0, geo.size.width - pad * 2)
                let n = DS.Shelf.compactColumnCount(forUsableWidth: usable)
                let w = DS.Shelf.compactCoverWidth(forUsableWidth: usable)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(w), spacing: spacing), count: n),
                            spacing: spacing
                        ) {
                            content
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(pad)
                }
            }
        }
    }
}

extension CoverGrid where Header == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.header = EmptyView()
        self.content = content()
    }
}
