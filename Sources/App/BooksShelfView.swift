import SwiftData
import SwiftUI

/// E-books library shelf. Renders downloaded books and navigates to the Readium
/// reader. Real downloads arrive in Phase 2; a DEBUG action imports the bundled
/// sample EPUB via `MockLibrarySource`.
struct BooksShelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Query(sort: \Book.title) private var books: [Book]
    @State private var importing = false

    private var columns: [GridItem] {
        let minWidth = hSizeClass == .regular
            ? DS.Shelf.minCoverWidthRegular
            : DS.Shelf.minCoverWidth
        return [GridItem(.adaptive(minimum: minWidth), spacing: DS.Shelf.spacing)]
    }

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
                                    CoverTile(title: book.title, subtitle: book.author, coverPath: book.coverPath)
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
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Scan now", systemImage: "arrow.clockwise") {
                    Task { await sync.scanNow() }
                }
                .disabled(sync.isScanning)
                #if DEBUG
                Button("Load samples", systemImage: "ladybug") {
                    Task { await loadSamples() }
                }
                .disabled(importing)
                #endif
            }
            .overlay(alignment: .top) {
                if sync.isScanning { ProgressView("Scanning Dropbox…").padding(DS.Spacing.sm) }
            }
            .alert("Scan failed", isPresented: Binding(
                get: { sync.lastError != nil },
                set: { if !$0 { sync.lastError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(sync.lastError ?? "")
            }
            .background(DS.Palette.shelfBackground)
            #if DEBUG
            .task {
                if CommandLine.arguments.contains("-loadsamples") && books.isEmpty {
                    await loadSamples()
                }
            }
            #endif
        }
    }

    #if DEBUG
    /// Full dev loop: mock list → download into container → import → persist.
    private func loadSamples() async {
        importing = true
        defer { importing = false }
        let mock = MockLibrarySource()
        let store = LibraryStore(context: modelContext)
        guard let entries = try? await mock.listFolder(DropboxConfig.booksPath) else { return }
        for entry in entries where entry.name.lowercased().hasSuffix(".epub") {
            do {
                let dest = try ContainerPaths.url(forRelativePath: "Books/\(entry.name)")
                try await mock.download(entry, to: dest)
                let book = try await EbookImporter.makeBook(fromLocal: dest)
                store.insert(book)
                try store.save()
            } catch {
                print("Sample EPUB import failed for \(entry.name): \(error)")
            }
        }
    }
    #endif
}
