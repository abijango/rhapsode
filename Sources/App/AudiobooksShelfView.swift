import SwiftData
import SwiftUI

/// Audiobooks library shelf. On-device books open the player; rhapsode-server
/// catalogue entries appear greyed until the user taps to download.
struct AudiobooksShelfView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Query(sort: \Audiobook.title) private var audiobooks: [Audiobook]
    @Query(sort: \LibraryCollection.name) private var allCollections: [LibraryCollection]
    @Environment(\.expandAudiobookPlayer) private var expandAudiobookPlayer
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openDownloads) private var openDownloads
    @Environment(AudiobookPlayer.self) private var player
    var showsShelfChrome = true
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

    private var pinnedContinue: [Audiobook] {
        Array(continueBooks.prefix(4))
    }

    private var libraryBooks: [Audiobook] {
        let pinnedIDs = Set(pinnedContinue.map(\.id))
        return audiobooks.filter { book in
            passesFilters(book) && !pinnedIDs.contains(book.id)
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

    private var downloadsBadge: Int {
        sync.downloadingRemoteEntryIDs.count
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            CollectionCircleBar(
                                collections: collections,
                                selectedID: $selectedCollectionID,
                                onManage: { showManageCollections = true }
                            )
                            VStack(alignment: .leading, spacing: 0) {
                                if !pinnedContinue.isEmpty {
                                    ShelfSectionHeader(title: "Continue")
                                    continueGrid
                                }
                                if (!libraryBooks.isEmpty || !remoteOnly.isEmpty) && !pinnedContinue.isEmpty {
                                    ShelfSectionHeader(title: "Library")
                                }
                                ForEach(libraryBooks) { book in
                                    audiobookLink(book)
                                }
                                ForEach(remoteOnly) { entry in
                                    remoteRow(entry)
                                }
                            }
                            .padding(.horizontal, DS.Spacing.md)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if sync.isScanning || sync.isRefreshingInBackground {
                    LibraryScanBanner(label: scanningLabel)
                }
            }
            .navigationTitle(showsShelfChrome ? "Audiobooks" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsShelfChrome ? .visible : .hidden, for: .automatic)
            .modifier(ShelfSearchModifier(text: $searchText, enabled: showsShelfChrome))
            .toolbar {
                if showsShelfChrome {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") {
                            openSettings?()
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        downloadsToolbarButton
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

    private var downloadsToolbarButton: some View {
        Button("Downloads", systemImage: "arrow.down.circle") {
            openDownloads?()
        }
        .badge(downloadsBadge)
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

    private var continueColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: DS.Shelf.spacing),
            GridItem(.flexible(), spacing: DS.Shelf.spacing),
        ]
    }

    @ViewBuilder
    private var continueGrid: some View {
        LazyVGrid(columns: continueColumns, spacing: DS.Shelf.spacing) {
            ForEach(pinnedContinue) { book in
                audiobookLink(book, style: .continue)
            }
        }
        .padding(.bottom, DS.Spacing.xs)
    }

    private func continueStatus(for book: Audiobook) -> ContinueCard.Status {
        if player.book?.id == book.id, player.isPlaying {
            return .playing
        }
        return .paused
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
        sync.isDownloadingRemoteEntry(entry.id)
    }

    private func remoteRow(_ entry: RemoteCatalogEntry) -> some View {
        let downloading = isDownloading(entry)
        return Button {
            guard !downloading else { return }
            Task { await sync.downloadRemote(entry) }
        } label: {
            LibraryListRow(
                title: entry.title,
                subtitle: downloading
                    ? "Downloading…"
                    : (entry.author ?? "On NAS · tap to download"),
                coverPath: sync.remoteCoverPath(for: entry.id),
                appearance: .remote
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

    private enum AudiobookLinkStyle {
        case `continue`
        case library
    }

    private func audiobookLink(_ book: Audiobook, style: AudiobookLinkStyle = .library) -> some View {
        Button {
            expandAudiobookPlayer?(book)
        } label: {
            switch style {
            case .continue:
                ContinueCard(
                    title: book.title,
                    coverPath: book.coverPath,
                    status: continueStatus(for: book)
                )
            case .library:
                LibraryListRow(
                    title: book.title,
                    subtitle: book.author,
                    coverPath: book.coverPath
                )
            }
        }
        .buttonStyle(.plain)
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

private struct ShelfSearchModifier: ViewModifier {
    @Binding var text: String
    var enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Title or author"
            )
        } else {
            content
        }
    }
}
