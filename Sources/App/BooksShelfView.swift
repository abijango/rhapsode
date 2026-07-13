import SwiftData
import SwiftUI

/// E-books library shelf. On-device books open the reader; rhapsode-server
/// catalogue entries appear greyed until the user taps to download.
struct BooksShelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Query(sort: \Book.title) private var books: [Book]
    @Query(sort: \LibraryCollection.name) private var allCollections: [LibraryCollection]
    @Query(sort: \DownloadItem.remoteEntryID) private var downloadItems: [DownloadItem]
    @State private var searchText = ""
    @State private var selectedCollectionID: UUID?
    @State private var showManageCollections = false
    @State private var assignBook: Book?

    private var collections: [LibraryCollection] {
        allCollections.filter { $0.kind == .books }
    }

    private var collectionStore: CollectionStore { CollectionStore(context: modelContext) }

    private func passesFilters(_ book: Book) -> Bool {
        LibraryShelf.matchesEbook(book, query: searchText)
            && LibraryShelf.inCollection(book.collections, filterID: selectedCollectionID)
    }

    private var continueBooks: [Book] {
        LibraryShelf.continueEbooks(books).filter(passesFilters)
    }

    private var libraryBooks: [Book] {
        let continueIDs = Set(continueBooks.map(\.id))
        return books.filter { book in
            passesFilters(book) && !continueIDs.contains(book.id)
        }
    }

    private var remoteOnly: [RemoteCatalogEntry] {
        guard selectedCollectionID == nil else { return [] }
        return sync.availableRemoteEntries(kind: .books)
            .filter { LibraryShelf.matchesRemote($0, query: searchText) }
            .sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    private var hasVisibleContent: Bool {
        !continueBooks.isEmpty || !libraryBooks.isEmpty || !remoteOnly.isEmpty
    }

    private var scanningLabel: String {
        if sync.usesSmbBackend { return "Refreshing NAS catalogue…" }
        if sync.usesServerBackend { return "Refreshing library…" }
        return "Scanning Dropbox…"
    }

    private var emptyDescription: String {
        if sync.usesSelectiveCatalog {
            return "Tap the library menu to refresh the catalogue, then tap a grey cover to download."
        }
        return "Drop an EPUB into your Dropbox Books folder."
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty && remoteOnly.isEmpty {
                    ContentUnavailableView(
                        "No E-books",
                        systemImage: "books.vertical",
                        description: Text(emptyDescription)
                    )
                } else if !hasVisibleContent {
                    emptyFiltered
                } else {
                    CoverGrid {
                        shelfHeader
                    } content: {
                        ForEach(libraryBooks) { book in
                            ebookLink(book)
                        }
                        ForEach(remoteOnly) { entry in
                            remoteTile(entry)
                        }
                    }
                }
            }
            .navigationTitle("E-books")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Title or author"
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if sync.usesSelectiveCatalog {
                        Menu {
                            Button("Refresh catalogue", systemImage: "arrow.clockwise") {
                                Task { await sync.refreshCatalog() }
                            }
                            if sync.usesServerBackend {
                                Button("Reindex library", systemImage: "externaldrive.badge.icloud") {
                                    Task { await sync.reindexLibrary(full: false) }
                                }
                                Button("Full rebuild…", systemImage: "arrow.triangle.2.circlepath") {
                                    Task { await sync.reindexLibrary(full: true) }
                                }
                            }
                        } label: {
                            Label("Library", systemImage: "arrow.clockwise")
                        }
                        .disabled(sync.isScanning)
                    } else {
                        Button("Scan now", systemImage: "arrow.clockwise") {
                            Task { await sync.scanNow() }
                        }
                        .disabled(sync.isScanning)
                    }
                }
            }
            .overlay(alignment: .top) {
                if sync.isScanning {
                    ProgressView(scanningLabel).padding(DS.Spacing.sm)
                }
            }
            .alert("Sync Issue", isPresented: Binding(
                get: { sync.lastError != nil },
                set: { if !$0 { sync.lastError = nil } }
            )) {
                Button("OK") {}
            } message: {
                Text(sync.lastError ?? "")
            }
            .sheet(isPresented: $showManageCollections) {
                ManageCollectionsView(
                    kind: .books,
                    collections: collections,
                    onCreate: { try createCollection(name: $0) },
                    onRename: { try renameCollection($0, to: $1) },
                    onDelete: { deleteCollection($0) }
                )
            }
            .sheet(item: $assignBook) { book in
                AssignCollectionSheet(
                    kind: .books,
                    title: book.title,
                    collections: collections,
                    isMember: { collectionStore.isMember($0, book: book) },
                    onToggle: { toggleCollection($0, book: book) },
                    onCreate: { name in
                        let created = try createCollection(name: name)
                        try collectionStore.toggleMembership(collection: created, book: book)
                        syncCollections()
                    }
                )
            }
            .background(DS.Palette.shelfBackground)
        }
    }

    @ViewBuilder
    private var emptyFiltered: some View {
        if selectedCollectionID != nil {
            ContentUnavailableView(
                "No E-books",
                systemImage: "folder",
                description: Text("No e-books in this collection.")
            )
        } else {
            ContentUnavailableView.search(text: searchText)
        }
    }

    @ViewBuilder
    private var shelfHeader: some View {
        CollectionFilterBar(
            collections: collections,
            selectedID: $selectedCollectionID,
            onManage: { showManageCollections = true }
        )
        if !continueBooks.isEmpty {
            ShelfSectionHeader(title: "Continue")
            ContinueShelfRow(items: continueBooks) { book in
                ebookLink(book)
            }
        }
        if (!libraryBooks.isEmpty || !remoteOnly.isEmpty) && !continueBooks.isEmpty {
            ShelfSectionHeader(title: "Library")
        }
    }

    @discardableResult
    private func createCollection(name: String) throws -> LibraryCollection {
        let created = try collectionStore.create(name: name, kind: .books)
        syncCollections()
        return created
    }

    private func renameCollection(_ collection: LibraryCollection, to name: String) throws {
        try collectionStore.rename(collection, to: name)
        syncCollections()
    }

    private func toggleCollection(_ collection: LibraryCollection, book: Book) {
        try? collectionStore.toggleMembership(collection: collection, book: book)
        syncCollections()
    }

    private func deleteCollection(_ collection: LibraryCollection) {
        if selectedCollectionID == collection.id { selectedCollectionID = nil }
        try? collectionStore.delete(collection)
        syncCollections()
    }

    private func syncCollections() {
        Task { await sync.pushCollections() }
    }

    private func isDownloading(_ entry: RemoteCatalogEntry) -> Bool {
        downloadItems.contains {
            $0.remoteEntryID == entry.id
                && ($0.state == .pending || $0.state == .downloading)
        }
    }

    private func remoteTile(_ entry: RemoteCatalogEntry) -> some View {
        let downloading = isDownloading(entry)
        return Button {
            guard !downloading else { return }
            Task { await sync.downloadRemote(entry) }
        } label: {
            CoverTile(
                title: entry.title,
                subtitle: downloading
                    ? "Downloading…"
                    : (entry.author ?? "On NAS · tap to download"),
                coverPath: sync.remoteCoverPath(for: entry.id),
                progress: nil,
                appearance: .remote,
                kind: .books
            )
            .overlay {
                if downloading {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(downloading)
        .tint(.primary)
        .task(id: entry.id) {
            await sync.ensureRemoteCover(for: entry)
        }
        .contextMenu {
            Button("Download", systemImage: "arrow.down.circle") {
                Task { await sync.downloadRemote(entry) }
            }
            .disabled(downloading)
        }
    }

    private func ebookLink(_ book: Book) -> some View {
        NavigationLink {
            ReaderView(book: book)
        } label: {
            CoverTile(
                title: book.title,
                subtitle: book.author,
                coverPath: book.coverPath,
                progress: book.fractionComplete,
                kind: .books
            )
        }
        .tint(.primary)
        .contextMenu {
            Button("Add to Collection…", systemImage: "folder.badge.plus") {
                assignBook = book
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                LibraryStore(context: modelContext).deleteBook(book)
            }
        }
    }
}
