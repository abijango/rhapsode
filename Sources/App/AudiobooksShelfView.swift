import SwiftData
import SwiftUI

/// Audiobooks library shelf. On-device books open the player; rhapsode-server
/// catalogue entries appear greyed until the user taps to download.
struct AudiobooksShelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Query(sort: \Audiobook.title) private var audiobooks: [Audiobook]
    @Query(sort: \LibraryCollection.name) private var allCollections: [LibraryCollection]
    @Query(sort: \DownloadItem.remoteEntryID) private var downloadItems: [DownloadItem]
    @State private var searchText = ""
    @State private var selectedCollectionID: UUID?
    @State private var showManageCollections = false
    @State private var assignAudiobook: Audiobook?

    private var collections: [LibraryCollection] {
        allCollections.filter { $0.kind == .audiobooks }
    }

    private var collectionStore: CollectionStore { CollectionStore(context: modelContext) }

    private func passesFilters(_ book: Audiobook) -> Bool {
        LibraryShelf.matchesAudiobook(book, query: searchText)
            && LibraryShelf.inCollection(book.collections, filterID: selectedCollectionID)
    }

    private var continueBooks: [Audiobook] {
        LibraryShelf.continueAudiobooks(audiobooks).filter(passesFilters)
    }

    private var libraryBooks: [Audiobook] {
        let continueIDs = Set(continueBooks.map(\.id))
        return audiobooks.filter { book in
            passesFilters(book) && !continueIDs.contains(book.id)
        }
    }

    /// Remote-only catalogue rows (hidden when filtering by collection).
    private var remoteOnly: [RemoteCatalogEntry] {
        guard selectedCollectionID == nil else { return [] }
        return sync.availableRemoteEntries(kind: .audiobooks)
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
            return sync.selectiveCatalogEmptyHint()
        }
        return "Drop an M4B or MP3 folder into your Dropbox Audiobooks folder."
    }

    private var libraryMenuBadge: Int {
        sync.newRemoteCount(kind: .audiobooks)
    }

    var body: some View {
        NavigationStack {
            Group {
                if audiobooks.isEmpty && remoteOnly.isEmpty {
                    ContentUnavailableView(
                        "No Audiobooks",
                        systemImage: "headphones",
                        description: Text(emptyDescription)
                    )
                } else if !hasVisibleContent {
                    emptyFiltered
                } else {
                    CoverGrid {
                        shelfHeader
                    } content: {
                        ForEach(libraryBooks) { book in
                            audiobookLink(book)
                        }
                        ForEach(remoteOnly) { entry in
                            remoteTile(entry)
                        }
                    }
                }
            }
            .navigationTitle("Audiobooks")
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
                        .badge(libraryMenuBadge)
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
                    kind: .audiobooks,
                    collections: collections,
                    onCreate: { try createCollection(name: $0) },
                    onRename: { try renameCollection($0, to: $1) },
                    onDelete: { deleteCollection($0) }
                )
            }
            .sheet(item: $assignAudiobook) { book in
                AssignCollectionSheet(
                    kind: .audiobooks,
                    title: book.title,
                    collections: collections,
                    isMember: { collectionStore.isMember($0, audiobook: book) },
                    onToggle: { toggleCollection($0, audiobook: book) },
                    onCreate: { name in
                        let created = try createCollection(name: name)
                        try collectionStore.toggleMembership(collection: created, audiobook: book)
                        syncCollections()
                    }
                )
            }
            .background(DS.Palette.shelfBackground)
        }
        .onAppear { sync.markRemoteCatalogSeen(kind: .audiobooks) }
    }

    @ViewBuilder
    private var emptyFiltered: some View {
        if selectedCollectionID != nil {
            ContentUnavailableView(
                "No Audiobooks",
                systemImage: "folder",
                description: Text("No audiobooks in this collection.")
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
                audiobookLink(book)
            }
        }
        if (!libraryBooks.isEmpty || !remoteOnly.isEmpty) && !continueBooks.isEmpty {
            ShelfSectionHeader(title: "Library")
        }
    }

    @discardableResult
    private func createCollection(name: String) throws -> LibraryCollection {
        let created = try collectionStore.create(name: name, kind: .audiobooks)
        syncCollections()
        return created
    }

    private func renameCollection(_ collection: LibraryCollection, to name: String) throws {
        try collectionStore.rename(collection, to: name)
        syncCollections()
    }

    private func toggleCollection(_ collection: LibraryCollection, audiobook: Audiobook) {
        try? collectionStore.toggleMembership(collection: collection, audiobook: audiobook)
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
                kind: .audiobooks
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

    private func audiobookLink(_ book: Audiobook) -> some View {
        NavigationLink {
            PlayerView(audiobook: book)
        } label: {
            CoverTile(
                title: book.title,
                subtitle: book.author,
                coverPath: book.coverPath,
                progress: book.fractionComplete,
                kind: .audiobooks
            )
        }
        .tint(.primary)
        .contextMenu {
            Button("Add to Collection…", systemImage: "folder.badge.plus") {
                assignAudiobook = book
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                LibraryStore(context: modelContext).deleteAudiobook(book)
                sync.invalidateOnDeviceCatalogCache()
            }
        }
    }
}
