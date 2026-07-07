import SwiftData
import SwiftUI

/// E-books library shelf. Renders downloaded books and navigates to the Readium
/// reader. Books arrive via the Dropbox download pipeline.
struct BooksShelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Query(sort: \Book.title) private var books: [Book]

    private var columns: [GridItem] { DS.Shelf.columns(regular: hSizeClass == .regular) }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    ContentUnavailableView(
                        "No E-books",
                        systemImage: "books.vertical",
                        description: Text("Drop an EPUB into your Dropbox Books folder.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: DS.Shelf.spacing) {
                            ForEach(books) { book in
                                NavigationLink {
                                    ReaderView(book: book)
                                } label: {
                                    CoverTile(
                                        title: book.title,
                                        subtitle: book.author,
                                        coverPath: book.coverPath,
                                        progress: book.fractionComplete
                                    )
                                }
                                .tint(.primary)
                                .contextMenu {
                                    Button("Delete", systemImage: "trash", role: .destructive) {
                                        LibraryStore(context: modelContext).deleteBook(book)
                                    }
                                }
                            }
                        }
                        .padding(DS.Spacing.md)
                    }
                }
            }
            .navigationTitle("E-books")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Scan now", systemImage: "arrow.clockwise") {
                    Task { await sync.scanNow() }
                }
                .disabled(sync.isScanning)
            }
            .overlay(alignment: .top) {
                if sync.isScanning { ProgressView("Scanning Dropbox…").padding(DS.Spacing.sm) }
            }
            .alert("Sync Issue", isPresented: Binding(
                get: { sync.lastError != nil },
                set: { if !$0 { sync.lastError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(sync.lastError ?? "")
            }
            .background(DS.Palette.shelfBackground)
        }
    }
}
