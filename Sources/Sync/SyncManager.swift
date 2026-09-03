import Foundation
import SwiftData

/// Owns the Dropbox → library pipeline: first-connect bootstrap, manual "Scan now",
/// and the download queue (tracked as `DownloadItem`s) with start/finish
/// notifications. The foreground watcher (2d) and background refresh (2e) feed
/// jobs into the same `process(...)` path so dedup and notifications are shared.
///
/// Transfers currently run in-app (foreground). The single transfer call is
/// isolated in `transfer(...)` so a background `URLSession` can be swapped in
/// later without touching the queue/dedup/import logic.
@MainActor
@Observable
final class SyncManager {
    let source: LibrarySource
    private let context: ModelContext
    private let notifier = NotificationService()
    /// Cross-device progress sync (Phase 5). Defaults to a no-op so the mock /
    /// background-refresh call sites need no change; the app injects
    /// `DropboxProgressSync`.
    private let progress: ProgressSync

    private(set) var isScanning = false
    var lastError: String?
    /// rhapsode-server catalogue (metadata only). Populated by `refreshCatalog` /
    /// server-mode scan; used for greyed shelf tiles + selective download.
    private(set) var remoteCatalog: [RemoteCatalogEntry] = []
    /// entry.id → container-relative cover path for remote (not-yet-downloaded) tiles.
    /// Populated lazily by `ensureRemoteCover` as shelf cells appear.
    private(set) var remoteCoverPaths: [String: String] = [:]
    /// In-flight cover fetches so scrolling the shelf doesn't stampede the NAS.
    private var remoteCoverInFlight: Set<String> = []
    /// True when the live `source` is rhapsode-server (selective catalog UI).
    var usesServerBackend: Bool { source is RhapsodeServerSource }
    /// True when the live `source` is SMB NAS (selective catalog UI).
    var usesSmbBackend: Bool { source is SmbLibrarySource }
    /// Selective catalogue (grey tiles) for server or SMB — not Dropbox auto-pull.
    var usesSelectiveCatalog: Bool { usesServerBackend || usesSmbBackend }
    /// Network path is up — grey remote tiles are shown only when true.
    private(set) var isRemoteLibraryOnline = true
    private let reachability = RemoteLibraryReachability()

    private var watcher: Task<Void, Never>?
    /// Remote catalogue entry ids the user has already seen on a shelf (listing-diff badge).
    private var seenRemoteCatalogIDs: Set<String> = []
    /// Cached on-device keys for `availableRemoteEntries` (rebuilt on import / scan).
    private var onDeviceCacheDirty = true
    private var onDeviceRelPaths: Set<String> = []
    private var onDeviceServerItemIds: Set<String> = []
    /// SMB longpoll is a 60s timer — debounce expensive catalogue / progress pulls.
    private var lastSmbCatalogRefresh: Date?
    private var lastSmbCatalogFingerprint: (count: Int, totalBytes: Int64)?
    private var lastSmbProgressPull: Date?
    private static let smbCatalogMinInterval: TimeInterval = 5 * 60
    private static let smbProgressMinInterval: TimeInterval = 5 * 60
    /// Whether the full-library scan has run yet this launch. The longpoll watcher
    /// only reports changes *after* each folder's seeded cursor, so it can never
    /// surface files that were already in Dropbox when this device connected. A
    /// one-shot full scan per launch closes that gap so every device converges on
    /// the same library.
    private var didInitialScan = false

    // MARK: WP-C — live auto-jump targets
    /// The app-lifetime audiobook player (wired in `RhapsodeApp`). When a newer remote
    /// position is merged for the book it currently holds, the player is re-seeked so
    /// (a) the open player jumps to the new position and (b) the player's cached
    /// in-memory position can't later write its stale value back over the merge.
    /// Weak: the player outlives `SyncManager` anyway, and the push callback already
    /// captures `self`, so a weak ref here avoids a needless retain cycle.
    weak var audioPlayer: AudiobookPlayer?
    /// The reader currently on screen + the book it shows (registered by `ReaderView`).
    /// When a newer remote locator is merged for that book, the open reader navigates to
    /// it. Weak so it clears automatically when the reader view goes away.
    weak var activeReader: (any ActiveEbookReader)?
    var activeReaderBookID: UUID?

    init(source: LibrarySource, context: ModelContext, progress: ProgressSync = NoopProgressSync()) {
        self.source = source
        self.context = context
        self.progress = progress
        seenRemoteCatalogIDs = Self.loadSeenCatalogIDs(storageKey: Self.seenCatalogStorageKey)
        reachability.start { [weak self] online in
            self?.isRemoteLibraryOnline = online
        }
        isRemoteLibraryOnline = true
    }

    // MARK: Foreground auto-detect (longpoll watcher)

    /// Start watching the two roots while the app is in the foreground: longpoll
    /// each cursor, and on changes pull the new files. Idempotent; cancels any
    /// prior watcher. No-op if not connected.
    func startWatching() {
        guard watcher == nil else { return }
        guard ((try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []).isEmpty == false else { return }
        watcher = Task { await self.watchLoop() }
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Called when the app becomes active. If connected but the watched folders
    /// were never seeded (e.g. connected before bootstrap existed), seed them now,
    /// then start watching. No-op if not connected.
    func ensureWatching() async {
        let hasFolders = !(((try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []).isEmpty)
        Self.log("ensureWatching: hasFolders=\(hasFolders)")
        if !hasFolders {
            do { try await bootstrap(); Self.log("bootstrap seeded folders") }
            catch LibrarySourceError.notAuthenticated { Self.log("not connected — no watch"); return }
            catch { Self.log("bootstrap failed: \(error)"); return }
        }
        startWatching()
        Self.log("watcher started")
        // First activation this launch: pull the FULL existing library. A device
        // connected after files were already in Dropbox would otherwise never see
        // them (the watcher only reports post-cursor changes). Cheap on reruns —
        // dedup skips anything already imported.
        if !didInitialScan {
            didInitialScan = true
            if usesSelectiveCatalog {
                await refreshCatalog(force: true)
            } else {
                await scanNow()
            }
        }
        // Then pull any progress other devices wrote while we were away — the books
        // just imported above are now present to match against.
        await pullAndMergeProgressIfNeeded(force: true)
        // Back up our own lifetime SmartSpeech stats too (LWW skips if the remote is newer).
        await pushSmartSpeechStats()
        await pushCollections()
    }

    // MARK: Cross-device progress sync (Phase 5)

    /// Push the current local resume position for one audiobook to the cloud.
    /// Call after the player has persisted locally (e.g. on leaving the player).
    func pushAudiobookProgress(sourcePath: String) async {
        guard let book = (try? context.fetch(FetchDescriptor<Audiobook>()))?
            .first(where: { $0.sourcePath == sourcePath }) else { return }
        // WP-A: TRANSMIT the existing change-time stamp; never overwrite with "now" at push
        // time — that would let an idle device clobber a newer remote with a stale position.
        let updatedAt: Date
        if let stamped = book.progressUpdatedAt {
            updatedAt = stamped
        } else if book.lastTrackIndex != 0 || book.lastOffsetSeconds != 0 {
            // Legacy row: real position but no stamp yet. Stamp once and reuse it.
            let now = Date()
            book.progressUpdatedAt = now
            try? context.save()
            updatedAt = now
        } else {
            // Never touched (nil stamp + zero position): nothing to sync — pushing a fresh
            // timestamp on a zero position is exactly the clobber we're avoiding.
            return
        }
        // Dropbox stores track index + in-track offset. Rhapsode Server stores
        // absolute source-domain seconds (server has no chapter map).
        let trackIndex: Int
        let offsetSeconds: Double
        if source is RhapsodeServerSource {
            trackIndex = 0
            offsetSeconds = book.playedSeconds
        } else {
            trackIndex = book.lastTrackIndex
            offsetSeconds = book.lastOffsetSeconds
        }
        let p = PlaybackProgress(
            key: sourcePath, kind: .audiobooks,
            lastTrackIndex: trackIndex, lastOffsetSeconds: offsetSeconds,
            readingLocatorJSON: nil, listenedSeconds: book.listenedSeconds,
            savedSeconds: book.smartSpeechSavedSeconds, updatedAt: updatedAt)
        await pushProgressWithRetry(p, label: "pushAudiobookProgress")
    }

    /// Push the current local reading position for one book to the cloud.
    func pushBookProgress(relPath: String) async {
        guard let b = (try? context.fetch(FetchDescriptor<Book>()))?
            .first(where: { $0.fileRelPath == relPath }) else { return }
        // WP-A: TRANSMIT the existing change-time stamp; never overwrite with "now" at push time.
        let updatedAt: Date
        if let stamped = b.progressUpdatedAt {
            updatedAt = stamped
        } else if b.readingLocator != nil {
            // Legacy row: real reading position but no stamp yet. (Books carry position in the
            // locator, not track/offset — those are hardcoded 0 here.) Stamp once and reuse it.
            let now = Date()
            b.progressUpdatedAt = now
            try? context.save()
            updatedAt = now
        } else {
            // Never read (nil stamp + nil locator): nothing to sync.
            return
        }
        let p = PlaybackProgress(
            key: relPath, kind: .books,
            lastTrackIndex: 0, lastOffsetSeconds: 0,
            readingLocatorJSON: b.readingLocator, readingSeconds: b.readingSeconds,
            updatedAt: updatedAt)
        await pushProgressWithRetry(p, label: "pushBookProgress")
    }

    /// Retry transient SMB/network failures quietly; only surface a user alert after
    /// all attempts fail (avoids one-shot collision / flaky Wi‑Fi looking “broken”).
    private func pushProgressWithRetry(_ p: PlaybackProgress, label: String) async {
        var lastErr: Error?
        for attempt in 0..<3 {
            do {
                try await progress.push(p)
                Self.log("\(label) ok key=\(p.key) updatedAt=\(p.updatedAt)")
                return
            } catch {
                lastErr = error
                if Self.isBenignProgressSyncError(error) { return }
                Self.log("\(label) attempt \(attempt) failed: \(error.localizedDescription)")
                try? await Task.sleep(for: .milliseconds(200 + attempt * 300))
            }
        }
        if let lastErr {
            lastError = Self.progressSyncErrorMessage(lastErr)
        }
    }

    /// Progress uploads kicked off from a debounced reader/player task are often cancelled
    /// when the user navigates away mid-flight (`NSURLErrorDomain -999`). That is expected
    /// — `onDisappear` fires a fresh trailing-edge push — and must not alarm the user.
    private static func isBenignProgressSyncError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == URLError.cancelled.rawValue { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSURLErrorDomain, underlying.code == URLError.cancelled.rawValue {
            return true
        }
        return false
    }

    /// User-facing message for a failed progress upload. The most common cause is a
    /// Dropbox token minted before the `files.content.write` scope was added — which
    /// fails silently and looks identical to "sync is broken" — so the message
    /// points the user at the reconnect that fixes it.
    private static func progressSyncErrorMessage(_ error: Error) -> String {
        Self.log("progress sync user alert: \(error)")
        if SmbConfig.shouldUseSmb {
            let detail = error.localizedDescription
            return "Couldn't sync progress to the NAS (SMB). Check that your user can write "
                + "to the sync folder (\(SmbConfig.syncPath)) on the share."
                + (detail.isEmpty ? "" : "\n\n\(detail)")
        }
        if RhapsodeServerConfig.shouldUseServer {
            return "Couldn't sync progress to Rhapsode Server. Check the server URL, "
                + "that you're on Tailscale/LAN, and that your device token is still valid."
        }
        return "Couldn't sync your reading progress to Dropbox. If this keeps happening, "
            + "disconnect and reconnect Dropbox in Settings on both devices."
    }

    /// Pull every remote progress record and apply each to the matching local
    /// model iff the remote is newer (last-writer-wins). Safe to call on launch /
    /// foreground; a missing sync folder or no write scope simply yields nothing.
    func pullAndMergeProgress() async {
        await pullAndMergeProgressIfNeeded(force: true)
    }

    /// SMB longpoll fires every ~60s — skip redundant pulls unless forced (launch / BG refresh).
    private func pullAndMergeProgressIfNeeded(force: Bool = false) async {
        if usesSmbBackend && !force {
            if let last = lastSmbProgressPull,
               Date().timeIntervalSince(last) < Self.smbProgressMinInterval {
                Self.log("pullAndMergeProgress skipped (SMB debounce)")
                return
            }
        }
        lastSmbProgressPull = Date()
        do {
            let remotes = try await progress.pullAll()
            var applied = 0
            for p in remotes {
                let before = applyRemoteProgressReturningApplied(p)
                if before { applied += 1 }
            }
            try? context.save()
            Self.log("pulled \(remotes.count) progress record(s), applied \(applied)")
        } catch {
            Self.log("pullAndMergeProgress failed: \(error.localizedDescription)")
        }
        await pullSmartSpeechStats()
        await pullAndMergeCollections()
    }

    /// Back up the lifetime SmartSpeech stats (time saved + time listened) to Dropbox. Single shared
    /// record, LWW by `updatedAt` (read-before-write guard inside `pushStats`).
    func pushSmartSpeechStats() async {
        let record = SmartSpeechStatsRecord(
            savedSeconds: SmartSpeechStats.totalSavedSeconds,
            playedSeconds: SmartSpeechStats.totalPlayedSeconds,
            updatedAt: SmartSpeechStats.updatedAt ?? Date())
        do { try await progress.pushStats(record) }
        catch { Self.log("pushSmartSpeechStats failed: \(error.localizedDescription)") }
    }

    /// Adopt the backed-up SmartSpeech stats if the remote record is newer (carry-over to a new
    /// device / reinstall). Called inside `pullAndMergeProgress`.
    private func pullSmartSpeechStats() async {
        guard let record = try? await progress.pullStats() else { return }
        if record.isNewer(than: SmartSpeechStats.updatedAt) {
            SmartSpeechStats.apply(savedSeconds: record.savedSeconds,
                               // Old records lack playedSeconds — keep the local total rather than zero it.
                               playedSeconds: record.playedSeconds ?? SmartSpeechStats.totalPlayedSeconds,
                               updatedAt: record.updatedAt)
        }
    }

    // MARK: Cross-device collections sync

    /// Back up local collection manifests for both shelves. Called on foreground activation
    /// and after any local collection mutation from the shelf UI.
    func pushCollections() async {
        for kind in [FolderKind.audiobooks, .books] {
            guard shouldPushCollections(kind: kind) else { continue }
            let manifest = buildCollectionsManifest(kind: kind)
            do { try await progress.pushCollections(manifest) }
            catch { Self.log("pushCollections(\(kind)) failed: \(error.localizedDescription)") }
        }
    }

    /// Pull remote collection manifests and adopt each shelf iff the remote is newer (LWW).
    private func pullAndMergeCollections() async {
        for kind in [FolderKind.audiobooks, .books] {
            guard let remote = try? await progress.pullCollections(kind: kind) else { continue }
            guard remote.isNewer(than: CollectionsSyncState.updatedAt(for: kind)) else { continue }
            applyCollectionsManifest(remote)
            CollectionsSyncState.setUpdatedAt(remote.updatedAt, for: kind)
            try? context.save()
            Self.log("pulled collections manifest for \(kind) (\(remote.collections.count) collection(s))")
        }
    }

    private func shouldPushCollections(kind: FolderKind) -> Bool {
        if CollectionsSyncState.updatedAt(for: kind) != nil { return true }
        let count = (try? context.fetch(FetchDescriptor<LibraryCollection>()))?
            .filter { $0.kind == kind }.count ?? 0
        return count > 0
    }

    private func buildCollectionsManifest(kind: FolderKind) -> CollectionsManifest {
        let collections = (try? context.fetch(FetchDescriptor<LibraryCollection>(
            sortBy: [SortDescriptor(\.name, comparator: .localizedStandard)]
        )))?.filter { $0.kind == kind } ?? []
        let wires = collections.map { collection -> CollectionWire in
            let keys: [String]
            switch kind {
            case .audiobooks: keys = collection.audiobooks.map(\.sourcePath).sorted()
            case .books: keys = collection.books.map(\.fileRelPath).sorted()
            }
            return CollectionWire(id: collection.id, name: collection.name, memberKeys: keys)
        }
        let updatedAt = CollectionsSyncState.updatedAt(for: kind)
            ?? collections.map(\.createdAt).max()
            ?? Date()
        return CollectionsManifest(kind: kind, collections: wires, updatedAt: updatedAt)
    }

    /// Replace one shelf's local collections with a newer remote manifest. Membership is keyed
    /// by stable container-relative paths (`sourcePath` / `fileRelPath`).
    private func applyCollectionsManifest(_ manifest: CollectionsManifest) {
        let kind = manifest.kind
        let localCollections = (try? context.fetch(FetchDescriptor<LibraryCollection>()))?
            .filter { $0.kind == kind } ?? []
        let remoteIDs = Set(manifest.collections.map(\.id))

        for local in localCollections where !remoteIDs.contains(local.id) {
            context.delete(local)
        }

        let audiobooksByKey = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Audiobook>())) ?? [])
                .map { ($0.sourcePath, $0) })
        let booksByKey = Dictionary(
            uniqueKeysWithValues: ((try? context.fetch(FetchDescriptor<Book>())) ?? [])
                .map { ($0.fileRelPath, $0) })

        for wire in manifest.collections {
            let collection: LibraryCollection
            if let existing = localCollections.first(where: { $0.id == wire.id }) {
                collection = existing
            } else {
                collection = LibraryCollection(id: wire.id, name: wire.name, kind: kind)
                context.insert(collection)
            }
            collection.name = wire.name
            switch kind {
            case .audiobooks:
                collection.audiobooks = wire.memberKeys.compactMap { audiobooksByKey[$0] }
            case .books:
                collection.books = wire.memberKeys.compactMap { booksByKey[$0] }
            }
        }
    }

    /// Apply one remote record to its matching local model when it wins LWW.
    /// Match is by the stable container-relative key (`sourcePath` / `fileRelPath`),
    /// or by rhapsode-server item id embedded as the second path component.
    private func applyRemoteProgress(_ p: PlaybackProgress) {
        _ = applyRemoteProgressReturningApplied(p)
    }

    /// - Returns: `true` if a position/locator was applied (LWW won).
    @discardableResult
    private func applyRemoteProgressReturningApplied(_ p: PlaybackProgress) -> Bool {
        switch p.kind {
        case .audiobooks:
            guard let book = (try? context.fetch(FetchDescriptor<Audiobook>()))?
                .first(where: { Self.progressKeysMatch($0.sourcePath, p.key) }) else {
                Self.log("pull skip audio — no local match for key=\(p.key)")
                return false
            }
            // WP8: listenedSeconds is a monotonic cumulative counter — merge with max regardless of the
            // position LWW guard, so a stale-position remote can't clobber a higher local listened total.
            if let remoteListened = p.listenedSeconds {
                book.listenedSeconds = max(book.listenedSeconds ?? 0, remoteListened)
            }
            // Per-book reclaimed time — same monotonic max-merge, so it survives reinstalls and
            // a stale-position remote can't lower it.
            if let remoteSaved = p.savedSeconds {
                book.smartSpeechSavedSeconds = max(book.smartSpeechSavedSeconds ?? 0, remoteSaved)
            }
            guard p.isNewer(than: book.progressUpdatedAt) else {
                Self.log("pull LWW skip audio key=\(p.key) remote=\(p.updatedAt) local=\(String(describing: book.progressUpdatedAt))")
                return false
            }
            // Server synthetic keys (`…/_server`) or live server pushes use absolute
            // source seconds with track index 0. Dropbox keeps chapter index + offset.
            let track: Int
            let offset: Double
            if p.key.hasSuffix("/_server") || source is RhapsodeServerSource {
                (track, offset) = Self.splitAbsolutePosition(
                    p.lastOffsetSeconds, tracks: book.orderedTracks)
            } else {
                track = p.lastTrackIndex
                offset = p.lastOffsetSeconds
            }
            book.lastTrackIndex = track
            book.lastOffsetSeconds = offset
            book.progressUpdatedAt = p.updatedAt
            // WP-C: if the app-lifetime player holds this book, reconcile its in-memory
            // position to the merged value (auto-jump + prevents the player from later
            // clobbering the merge with its stale cached position). No-op (anti-echo)
            // inside the player: it does NOT re-stamp or re-push the applied position.
            audioPlayer?.applyRemotePosition(
                bookID: book.id, trackIndex: track, offsetSeconds: offset)
            Self.log("pull applied audio key=\(p.key)")
            return true
        case .books:
            guard let b = (try? context.fetch(FetchDescriptor<Book>()))?
                .first(where: { Self.progressKeysMatch($0.fileRelPath, p.key) }) else {
                Self.log("pull skip book — no local match for key=\(p.key)")
                return false
            }
            if let remoteReading = p.readingSeconds {
                b.readingSeconds = max(b.readingSeconds ?? 0, remoteReading)
            }
            guard p.isNewer(than: b.progressUpdatedAt) else {
                Self.log("pull LWW skip book key=\(p.key) remote=\(p.updatedAt) local=\(String(describing: b.progressUpdatedAt))")
                return false
            }
            b.readingLocator = p.readingLocatorJSON
            b.progressUpdatedAt = p.updatedAt
            // WP-C: if this book is open in the reader, auto-jump it to the merged locator.
            // FoliateWebReader decodes the JSON itself (keeps WebKit out of SyncManager).
            if activeReaderBookID == b.id, let json = p.readingLocatorJSON {
                activeReader?.applyRemoteLocator(json: json)
            }
            Self.log("pull applied book key=\(p.key)")
            return true
        }
    }

    private func watchLoop() async {
        await withTaskGroup(of: Void.self) { group in
            let folders = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
            for folder in folders {
                let id = folder.persistentModelID
                group.addTask { await self.watch(folderID: id) }
            }
            // WP-C: also longpoll the cross-device progress folder so a position written
            // by another device is pulled+merged in near-real-time while foregrounded.
            group.addTask { await self.watchProgress() }
        }
    }

    /// Longpoll the `/.rhapsode-sync` progress folder; on any change, pull+merge so the
    /// shelf %, an open player, or an open reader update without waiting for a relaunch.
    /// The folder may not exist until the first push from any device — tolerate that
    /// (back off, then re-seed the cursor and retry). Never ingests its files as library
    /// content (it is not a `WatchedFolder` and `pullAndMergeProgress` reads it directly).
    private func watchProgress() async {
        // Progress folder path depends on backend (Dropbox app folder vs SMB share).
        let progressFolder: String = {
            if usesSmbBackend { return SmbProgressSync.folder }
            return DropboxProgressSync.folder
        }()
        // Server progress is polled via its own API elsewhere; skip Dropbox-style watch.
        if usesServerBackend { return }

        var cursor: String?
        while !Task.isCancelled {
            do {
                if cursor == nil {
                    cursor = try await source.latestCursor(progressFolder)
                }
                guard let c = cursor else { return }
                let hasChanges = try await source.longpoll(cursor: c)
                if Task.isCancelled { return }
                if hasChanges {
                    // SMB longpoll is a timer; always pull. Dropbox uses real deltas.
                    if usesSmbBackend {
                        cursor = try? await source.latestCursor(progressFolder)
                        await pullAndMergeProgressIfNeeded()
                    } else {
                        let (_, newCursor) = try await source.changes(since: c)
                        cursor = newCursor
                        await pullAndMergeProgress()
                    }
                }
            } catch {
                // Folder missing (no push yet) or transient error — re-seed + back off.
                Self.log("watchProgress error: \(error) — backing off")
                cursor = nil
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Longpoll one folder until cancelled.
    /// Dropbox: ingest (auto-download) new entries. Selective catalogue (server/SMB):
    /// only refresh remote metadata — never pull files without an explicit user tap.
    private func watch(folderID: PersistentIdentifier) async {
        while !Task.isCancelled {
            guard let folder = self[folderID], let cursor = folder.cursor else { return }
            let kind = folder.kind
            do {
                Self.log("longpoll start \(kind)")
                let hasChanges = try await source.longpoll(cursor: cursor)
                if Task.isCancelled { return }
                Self.log("longpoll \(kind) → changes=\(hasChanges)")
                if hasChanges {
                    if usesSelectiveCatalog {
                        // SMB longpoll is a timer that always reports "maybe changes";
                        // never call process() — only refresh grey-tile catalogue.
                        await refreshCatalogIfNeeded()
                        // Advance cursor so we don't thrash the same list forever.
                        if let folder = self[folderID] {
                            let (_, newCursor) = (try? await source.changes(since: cursor))
                                ?? ([], cursor)
                            folder.cursor = newCursor
                            try? context.save()
                        }
                    } else {
                        let (entries, newCursor) = try await source.changes(since: cursor)
                        guard let folder = self[folderID] else { return }
                        folder.cursor = newCursor
                        try? context.save()
                        let jobs = entries.filter { Self.belongs($0, to: kind) }.map { ($0, kind) }
                        Self.log("changes \(kind) → \(entries.count) entries, \(jobs.count) to ingest")
                        await ingest(jobs)
                    }
                }
            } catch {
                Self.log("watch \(kind) error: \(error) — backing off")
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    static func log(_ message: String) {
        #if DEBUG
        print("RHAPSODE-SYNC: \(message)")
        #endif
    }

    /// Resolve a watched folder by ID, returning nil if it has been DELETED from the store.
    ///
    /// Must NOT use `context.model(for:)`: that returns an *invalidated* instance (not nil) for a
    /// deleted row, and reading any property of it traps ("backing data could no longer be found").
    /// The watch loop holds a folder ID across `await` suspensions, during which the row can be
    /// deleted (a role switch prunes stale folders — WP5; the self-test deletes them too). A
    /// fetch-and-match returns nil so the loop ends cleanly instead of crashing.
    private subscript(id: PersistentIdentifier) -> WatchedFolder? {
        (try? context.fetch(FetchDescriptor<WatchedFolder>()))?.first { $0.persistentModelID == id }
    }

    /// Keep only entries whose path sits under this folder's root.
    private static func belongs(_ entry: RemoteEntry, to kind: FolderKind) -> Bool {
        let root = kind == .audiobooks ? DropboxConfig.audiobooksPath : DropboxConfig.booksPath
        return entry.path.hasPrefix(root + "/") || entry.path == root
    }

    // MARK: First-connect bootstrap

    /// Create the two watched roots if missing and seed a `WatchedFolder` (with a
    /// "watch from now" cursor) for each, if not already present.
    func bootstrap() async throws {
        try await source.authenticate()
        let existing = Set(try context.fetch(FetchDescriptor<WatchedFolder>()).map(\.kind))
        for (kind, path) in Self.roots {
            // Best-effort: creating a folder needs write scope, which the (read-only)
            // app doesn't have. If it fails, the user just creates the folder in
            // Dropbox themselves. We only watch folders we can read a cursor for.
            try? await source.ensureFolderExists(path)
            guard !existing.contains(kind) else { continue }
            do {
                let cursor = try await source.latestCursor(path)
                context.insert(WatchedFolder(kind: kind, remotePath: path, cursor: cursor))
                Self.log("seeded \(kind) cursor")
            } catch {
                // Folder doesn't exist yet (or unreadable) — skip; seed it on a later
                // connect/scan once the user has created it.
                Self.log("could not seed \(kind): \(error.localizedDescription)")
            }
        }
        try context.save()
    }

    // MARK: Manual scan / selective catalog

    /// List both roots and download/import anything new (Dropbox), or refresh the
    /// remote catalogue without downloading (rhapsode-server / SMB selective).
    func scanNow() async {
        if usesSelectiveCatalog {
            await refreshCatalog(force: true)
            return
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            try await source.authenticate()
        } catch {
            lastError = "Connect Dropbox in Settings first."
            return
        }
        for (kind, path) in Self.roots {
            do {
                for entry in try await source.listFolder(path) {
                    await process(entry, kind: kind)
                }
            } catch {
                // One missing/unreadable root shouldn't abort the other.
                Self.log("scan \(kind) failed: \(error.localizedDescription)")
            }
        }
    }

    /// Load remote catalogue without downloading (server SQLite or SMB list).
    /// Does **not** enqueue downloads — user picks tiles on the shelf.
    /// Server disk re-index: `reindexLibrary(full:)`.
    func refreshCatalog(force: Bool = false) async {
        await refreshCatalogIfNeeded(force: force)
    }

    private func refreshCatalogIfNeeded(force: Bool = false) async {
        if usesSmbBackend && !force {
            if let last = lastSmbCatalogRefresh,
               Date().timeIntervalSince(last) < Self.smbCatalogMinInterval {
                Self.log("refreshCatalog skipped (SMB debounce)")
                return
            }
        }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            try await source.authenticate()
        } catch {
            lastError = usesSmbBackend
                ? "Connect SMB (NAS) in Settings first."
                : (usesServerBackend
                    ? "Connect Rhapsode Server in Settings first."
                    : "Connect Dropbox in Settings first.")
            return
        }
        do {
            let catalog: [RemoteCatalogEntry]
            if let server = source as? RhapsodeServerSource {
                catalog = try await server.listCatalog()
            } else if let smb = source as? SmbLibrarySource {
                catalog = try await smb.listCatalog()
            } else {
                lastError = "Catalogue refresh is only for SMB or Rhapsode Server."
                return
            }
            let fingerprint = Self.catalogFingerprint(catalog)
            if usesSmbBackend && !force,
               let last = lastSmbCatalogFingerprint,
               last == fingerprint {
                lastSmbCatalogRefresh = Date()
                Self.log("refreshCatalog skipped (SMB fingerprint unchanged)")
                return
            }
            remoteCatalog = catalog
            lastSmbCatalogFingerprint = fingerprint
            if usesSmbBackend {
                lastSmbCatalogRefresh = Date()
            }
            invalidateOnDeviceCatalogCache()
            seedSeenCatalogIfNeeded()
            Self.log("catalog refreshed: \(remoteCatalog.count) item(s)")
        } catch {
            lastError = "Couldn't refresh library: \(error.localizedDescription)"
            Self.log("refreshCatalog failed: \(error)")
        }
    }

    private static func catalogFingerprint(_ catalog: [RemoteCatalogEntry]) -> (Int, Int64) {
        (catalog.count, catalog.reduce(Int64(0)) { $0 + $1.sizeBytes })
    }

    /// Call after a local import or shelf delete so grey-tile availability stays accurate.
    func invalidateOnDeviceCatalogCache() {
        onDeviceCacheDirty = true
    }

    private func rebuildOnDeviceCatalogCacheIfNeeded() {
        guard onDeviceCacheDirty else { return }
        var rels = Set<String>()
        var serverIds = Set<String>()
        for a in (try? context.fetch(FetchDescriptor<Audiobook>())) ?? [] {
            rels.insert(a.sourcePath)
            if let id = RhapsodeServerSource.itemId(fromLocalRelPath: a.sourcePath) {
                serverIds.insert(id)
            }
        }
        for b in (try? context.fetch(FetchDescriptor<Book>())) ?? [] {
            rels.insert(b.fileRelPath)
            if let id = RhapsodeServerSource.itemId(fromLocalRelPath: b.fileRelPath) {
                serverIds.insert(id)
            }
        }
        onDeviceRelPaths = rels
        onDeviceServerItemIds = serverIds
        onDeviceCacheDirty = false
    }

    /// Server-only: ask the NAS to re-index the library folders, then reload the catalogue.
    /// - Parameter full: `true` rebuilds every row; `false` is incremental (new/changed/deleted only).
    func reindexLibrary(full: Bool = false) async {
        guard let server = source as? RhapsodeServerSource else { return }
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        do {
            try await source.authenticate()
            try await server.sharedClient.scanLibrary(mode: full ? "full" : "incremental")
            remoteCatalog = try await server.listCatalog()
            invalidateOnDeviceCatalogCache()
            Self.log("reindex (\(full ? "full" : "incremental")) done: \(remoteCatalog.count) item(s)")
        } catch {
            lastError = "Couldn't reindex library: \(error.localizedDescription)"
            Self.log("reindexLibrary failed: \(error)")
        }
    }

    /// Selective download of one catalogue entry (server or SMB).
    func downloadRemote(_ entry: RemoteCatalogEntry) async {
        guard usesSelectiveCatalog else { return }
        do { try await source.authenticate() }
        catch {
            lastError = usesSmbBackend
                ? "Connect SMB (NAS) in Settings first."
                : "Connect Rhapsode Server in Settings first."
            return
        }
        await process(entry.asRemoteEntry(), kind: entry.kind)
    }

    /// Cached relative cover path for a remote catalogue tile, if already fetched.
    func remoteCoverPath(for entryID: String) -> String? {
        if let path = remoteCoverPaths[entryID] { return path }
        if let disk = RemoteCoverCache.existingPath(forEntryId: entryID) {
            remoteCoverPaths[entryID] = disk
            return disk
        }
        return nil
    }

    /// Lazily pull cover art for a remote tile (SMB sidecar / EPUB embed).
    /// Safe to call from every cell's `.task` — deduped + disk-cached.
    func ensureRemoteCover(for entry: RemoteCatalogEntry) async {
        guard usesSelectiveCatalog else { return }
        if remoteCoverPath(for: entry.id) != nil { return }
        if RemoteCoverCache.hasFailed(forEntryId: entry.id) { return }
        guard !remoteCoverInFlight.contains(entry.id) else { return }
        remoteCoverInFlight.insert(entry.id)
        defer { remoteCoverInFlight.remove(entry.id) }

        do {
            try await source.authenticate()
            let data: Data?
            if let smb = source as? SmbLibrarySource {
                data = try await smb.fetchCoverData(for: entry)
            } else {
                // Server cover endpoint not shipped yet — no-op.
                data = nil
            }
            guard let data,
                  let path = try RemoteCoverCache.store(imageData: data, forEntryId: entry.id) else {
                RemoteCoverCache.markFailed(forEntryId: entry.id)
                return
            }
            remoteCoverPaths[entry.id] = path
        } catch {
            Self.log("remote cover \(entry.title): \(error.localizedDescription)")
            RemoteCoverCache.markFailed(forEntryId: entry.id)
        }
    }

    /// Catalogue entries for one shelf that are not already imported on device.
    /// Hidden when offline (Phase C: no unreachable grey tiles).
    func availableRemoteEntries(kind: FolderKind) -> [RemoteCatalogEntry] {
        guard usesSelectiveCatalog, isRemoteLibraryOnline else { return [] }
        return remoteEntriesNotOnDevice(kind: kind)
    }

    /// Unseen remote catalogue rows for one shelf (listing-diff badge).
    func newRemoteCount(kind: FolderKind) -> Int {
        guard usesSelectiveCatalog else { return 0 }
        return remoteEntriesNotOnDevice(kind: kind)
            .filter { !seenRemoteCatalogIDs.contains($0.id) }
            .count
    }

    /// Clear the listing-diff badge after the user opens a shelf.
    func markRemoteCatalogSeen(kind: FolderKind) {
        guard usesSelectiveCatalog else { return }
        var changed = false
        for entry in remoteEntriesNotOnDevice(kind: kind) {
            if seenRemoteCatalogIDs.insert(entry.id).inserted { changed = true }
        }
        if changed { persistSeenCatalogIDs() }
    }

    /// Hint for an empty selective-catalog shelf (offline vs online).
    func selectiveCatalogEmptyHint() -> String {
        if !isRemoteLibraryOnline {
            return "Connect to your network to browse titles on your library."
        }
        return "Tap the library menu to refresh the catalogue, then tap a grey cover to download."
    }

    private func remoteEntriesNotOnDevice(kind: FolderKind) -> [RemoteCatalogEntry] {
        rebuildOnDeviceCatalogCacheIfNeeded()
        return remoteCatalog.filter { entry in
            entry.kind == kind && !isCatalogEntryOnDevice(entry)
        }
    }

    private static var seenCatalogStorageKey: String {
        if SmbConfig.shouldUseSmb, let id = SmbConfig.activeProfileId {
            return "rhapsode.catalog.seen.smb.\(id.uuidString)"
        }
        if RhapsodeServerConfig.shouldUseServer {
            let host = RhapsodeServerConfig.activeBaseURLString
                ?? RhapsodeServerConfig.baseURLString
            return "rhapsode.catalog.seen.server.\(host)"
        }
        return "rhapsode.catalog.seen.none"
    }

    private static func loadSeenCatalogIDs(storageKey: String) -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(list)
    }

    private func persistSeenCatalogIDs() {
        let key = Self.seenCatalogStorageKey
        if let data = try? JSONEncoder().encode(Array(seenRemoteCatalogIDs)) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// First successful catalogue load: treat everything as already seen (no badge flood).
    private func seedSeenCatalogIfNeeded() {
        guard usesSelectiveCatalog else { return }
        let seededKey = Self.seenCatalogStorageKey + ".seeded"
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        for kind in [FolderKind.audiobooks, .books] {
            for entry in remoteEntriesNotOnDevice(kind: kind) {
                seenRemoteCatalogIDs.insert(entry.id)
            }
        }
        persistSeenCatalogIDs()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    private func isCatalogEntryOnDevice(_ entry: RemoteCatalogEntry) -> Bool {
        if onDeviceRelPaths.contains(entry.localRelPath) { return true }
        if let itemId = entry.serverItemId, onDeviceServerItemIds.contains(itemId) { return true }
        return false
    }

    /// Feed jobs discovered by the watcher / background refresh into the queue.
    /// Selective catalogue (server + SMB): refresh metadata only — never auto-download.
    /// Dropbox: enqueue every new file (existing auto-pull behaviour).
    func ingest(_ jobs: [(entry: RemoteEntry, kind: FolderKind)]) async {
        if usesSelectiveCatalog {
            await refreshCatalog()
            return
        }
        for job in jobs { await process(job.entry, kind: job.kind) }
    }

    /// One-shot delta check (no longpoll) for `BGTaskScheduler` background refresh.
    /// Dropbox: enqueue new files. Server/SMB: refresh catalogue only (no auto-download).
    func backgroundDeltaCheck() async {
        if usesSelectiveCatalog {
            await refreshCatalog(force: true)
            await pullAndMergeProgressIfNeeded(force: true)
            return
        }
        do { try await source.authenticate() } catch { return }
        let folders = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
        for folder in folders {
            guard let cursor = folder.cursor else { continue }
            do {
                let (entries, newCursor) = try await source.changes(since: cursor)
                folder.cursor = newCursor
                try? context.save()
                let kind = folder.kind
                await ingest(entries.filter { Self.belongs($0, to: kind) }.map { ($0, kind) })
            } catch {
                continue
            }
        }
        // WP-C: also pull cross-device progress so the shelf % / resume position refresh
        // opportunistically while the app is suspended (OS-gated best-effort).
        await pullAndMergeProgressIfNeeded(force: true)
    }

    /// Ask for notification permission (call once, e.g. after connecting).
    func requestNotificationPermission() async {
        await notifier.requestAuthorization()
    }

    // MARK: One item: dedup → download → import → notify

    private func process(_ entry: RemoteEntry, kind: FolderKind) async {
        guard Self.isAcceptable(entry, kind: kind) else { return }
        let rel = relPath(for: entry, kind: kind)
        guard !isAlreadyImported(rel: rel, kind: kind) else { return }

        if entry.isFolder {
            guard !isFolderInFlight(folderRel: rel) else { return }
            if let dbx = source as? DropboxSource {
                await processFolderBackground(entry: entry, kind: kind, folderRel: rel, dbx: dbx)
            } else {
                await processFolderInline(entry: entry, kind: kind, folderRel: rel)
            }
            return
        }

        guard !isInFlight(remoteEntryID: entry.id) else { return }

        let title = remoteCatalog.first(where: { $0.id == entry.id })?.title
            ?? Self.displayTitle(for: entry)
        let item = DownloadItem(
            remoteEntryID: entry.id,
            title: title,
            kind: kind,
            state: .downloading,
            totalBytes: entry.size,
            remotePath: entry.path)
        context.insert(item)
        try? context.save()
        await notifier.notifyDownloadStarted(title: title)

        // Route single files to the background URLSession when the source can build a
        // URLRequest (Dropbox / rhapsode-server); fall back to inline for MockLibrarySource.
        if let dbx = source as? DropboxSource {
            do {
                let req = try await dbx.downloadRequest(for: entry.path)
                BackgroundDownloader.shared.registerDownloadItem(item)
                BackgroundDownloader.shared.enqueue(request: req, item: item, destRelPath: rel)
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to enqueue \(title): \(error.localizedDescription)"
            }
        } else if let server = source as? RhapsodeServerSource {
            do {
                let req = try await server.downloadRequest(for: entry.path)
                BackgroundDownloader.shared.registerDownloadItem(item)
                BackgroundDownloader.shared.enqueue(request: req, item: item, destRelPath: rel)
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to enqueue \(title): \(error.localizedDescription)"
            }
        } else {
            do {
                let dest = try ContainerPaths.url(forRelativePath: rel)
                try await transfer(entry, to: dest)
                try await importItem(at: dest, kind: kind)
                context.delete(item)
                try context.save()
                invalidateOnDeviceCatalogCache()
                await notifier.notifyDownloadFinished(title: title)
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to download \(title): \(error.localizedDescription)"
            }
        }
    }

    /// Match Dropbox path equality, or rhapsode-server item id (2nd path component).
    private static func progressKeysMatch(_ local: String, _ remote: String) -> Bool {
        if local == remote { return true }
        guard let a = RhapsodeServerSource.itemId(fromLocalRelPath: local),
              let b = RhapsodeServerSource.itemId(fromLocalRelPath: remote) else {
            return false
        }
        return a == b
    }

    /// Map absolute source seconds into (trackIndex, offsetWithinTrack).
    private static func splitAbsolutePosition(
        _ absolute: Double,
        tracks: [AudiobookTrack]
    ) -> (Int, Double) {
        guard !tracks.isEmpty else { return (0, max(0, absolute)) }
        var remaining = max(0, absolute)
        for (i, t) in tracks.enumerated() {
            if remaining <= t.duration || i == tracks.count - 1 {
                return (i, min(remaining, t.duration))
            }
            remaining -= t.duration
        }
        return (tracks.count - 1, tracks.last?.duration ?? 0)
    }

    /// Phase 3b: list an MP3-folder's children, enqueue one background task per file,
    /// and import the folder once every child reaches `.done`.
    private func processFolderBackground(
        entry: RemoteEntry,
        kind: FolderKind,
        folderRel: String,
        dbx: DropboxSource
    ) async {
        let children: [RemoteEntry]
        do {
            children = try await source.listFolder(entry.path)
                .filter { Self.isFolderChildAcceptable($0) }
        } catch {
            lastError = "Failed to list \(entry.name): \(error.localizedDescription)"
            return
        }
        guard !children.isEmpty else { return }

        let groupID = UUID().uuidString
        await notifier.notifyDownloadStarted(title: entry.name)

        for child in children {
            let destRel = "\(folderRel)/\(child.name)"
            let item = DownloadItem(
                remoteEntryID: child.id,
                title: child.name,
                kind: kind,
                state: .downloading,
                totalBytes: child.size,
                groupID: groupID,
                groupFolderRelPath: folderRel,
                remotePath: child.path
            )
            context.insert(item)
            try? context.save()

            do {
                let req = try await dbx.downloadRequest(for: child.path)
                BackgroundDownloader.shared.registerDownloadItem(item)
                BackgroundDownloader.shared.enqueue(
                    request: req,
                    item: item,
                    destRelPath: destRel,
                    groupTitle: entry.name
                )
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to enqueue \(child.name): \(error.localizedDescription)"
            }
        }
    }

    /// Foreground folder transfer for MockLibrarySource (tests, debug).
    private func processFolderInline(entry: RemoteEntry, kind: FolderKind, folderRel: String) async {
        let item = DownloadItem(remoteEntryID: entry.id, title: entry.name, kind: kind,
                                state: .downloading, totalBytes: entry.size,
                                remotePath: entry.path)
        context.insert(item)
        try? context.save()
        await notifier.notifyDownloadStarted(title: entry.name)

        do {
            let dest = try ContainerPaths.url(forRelativePath: folderRel)
            try await transfer(entry, to: dest)
            try await importItem(at: dest, kind: kind)
            context.delete(item)
            try context.save()
            invalidateOnDeviceCatalogCache()
            await notifier.notifyDownloadFinished(title: entry.name)
        } catch {
            item.state = .failed
            try? context.save()
            lastError = "Failed to download \(entry.name): \(error.localizedDescription)"
        }
    }

    // MARK: Download retry

    /// Re-enqueue failed background transfers for one queue row (single file or MP3-folder group).
    func retryDownload(_ row: DownloadQueueRow) async {
        do { try await source.authenticate() }
        catch {
            lastError = RhapsodeServerConfig.shouldUseServer
                ? "Connect Rhapsode Server in Settings first."
                : "Connect Dropbox in Settings first."
            return
        }

        let groupTitle = row.isGroup ? row.title : nil
        for item in row.items where item.state == .failed {
            guard let remotePath = item.remotePath else { continue }
            let destRel = Self.destRelPath(for: item)
            item.state = .downloading
            item.bytesReceived = 0
            try? context.save()

            do {
                let req: URLRequest
                if let dbx = source as? DropboxSource {
                    req = try await dbx.downloadRequest(for: remotePath)
                } else if let server = source as? RhapsodeServerSource {
                    req = try await server.downloadRequest(for: remotePath)
                } else {
                    lastError = "Retry is only available for Dropbox or Rhapsode Server downloads."
                    item.state = .failed
                    try? context.save()
                    continue
                }
                BackgroundDownloader.shared.registerDownloadItem(item)
                BackgroundDownloader.shared.enqueue(
                    request: req,
                    item: item,
                    destRelPath: destRel,
                    groupTitle: groupTitle
                )
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to retry \(item.title ?? "download"): \(error.localizedDescription)"
            }
        }
    }

    /// Remove a failed queue row from the history (does not delete any downloaded files).
    func dismissDownload(_ row: DownloadQueueRow) {
        for item in row.items { context.delete(item) }
        try? context.save()
    }

    static func destRelPath(for item: DownloadItem) -> String {
        if let folder = item.groupFolderRelPath, let name = item.title {
            return "\(folder)/\(name)"
        }
        if let path = item.remotePath, path.hasPrefix("/") {
            return String(path.dropFirst())
        }
        return item.remotePath ?? ""
    }

    /// Foreground transfer — used by MockLibrarySource (tests) and folder entries.
    private func transfer(_ entry: RemoteEntry, to destination: URL) async throws {
        // Brief yield while audiobook playback is active so SMB I/O doesn't starve buffers.
        if usesSmbBackend, audioPlayer?.isPlaying == true {
            try? await Task.sleep(for: .milliseconds(500))
        }
        try await source.download(entry, to: destination)
    }

    private func importItem(at dest: URL, kind: FolderKind) async throws {
        switch kind {
        case .audiobooks:
            let audiobook = try await AudiobookImporter.makeAudiobook(fromLocal: dest)
            context.insert(audiobook)
            try context.save()
            invalidateOnDeviceCatalogCache()
            // Playback is LIVE silence-trimming now; no auto batch-render on import (it would
            // produce a .m4a nothing plays). Batch rendering is on-demand from Settings (WP5).
        case .books:
            context.insert(try await EbookImporter.makeBook(fromLocal: dest))
            try context.save()
            invalidateOnDeviceCatalogCache()
        }
    }

    // MARK: Dedup helpers

    private func isAlreadyImported(rel: String, kind: FolderKind) -> Bool {
        switch kind {
        case .audiobooks:
            return (try? context.fetch(FetchDescriptor<Audiobook>()))?.contains { $0.sourcePath == rel } ?? false
        case .books:
            return (try? context.fetch(FetchDescriptor<Book>()))?.contains { $0.fileRelPath == rel } ?? false
        }
    }

    private func isInFlight(remoteEntryID: String) -> Bool {
        let items = (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []
        return items.contains {
            $0.remoteEntryID == remoteEntryID && ($0.state == .pending || $0.state == .downloading)
        }
    }

    /// True when any child transfer for this MP3-folder group is still active.
    private func isFolderInFlight(folderRel: String) -> Bool {
        let items = (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []
        return items.contains {
            $0.groupFolderRelPath == folderRel && ($0.state == .pending || $0.state == .downloading)
        }
    }

    private func relPath(for entry: RemoteEntry, kind: FolderKind) -> String {
        (kind == .audiobooks ? "Audiobooks/" : "Books/") + entry.name
    }

    /// User-facing title: strip the server `itemId/` prefix when present.
    private static func displayTitle(for entry: RemoteEntry) -> String {
        if let slash = entry.name.lastIndex(of: "/") {
            return String(entry.name[entry.name.index(after: slash)...])
        }
        return entry.name
    }

    /// Only queue items we know how to import: EPUBs in Books; M4B/MP3 files or
    /// MP3 folders in Audiobooks.
    private static func isAcceptable(_ entry: RemoteEntry, kind: FolderKind) -> Bool {
        let name = entry.name.lowercased()
        switch kind {
        case .books:
            return !entry.isFolder && name.hasSuffix(".epub")
        case .audiobooks:
            return entry.isFolder || name.hasSuffix(".m4b") || name.hasSuffix(".mp3")
        }
    }

    /// Children to pull when downloading an MP3-folder audiobook in the background.
    private static func isFolderChildAcceptable(_ entry: RemoteEntry) -> Bool {
        let name = entry.name.lowercased()
        return !entry.isFolder
            && (name.hasSuffix(".mp3") || name == "cover.jpg" || name == "folder.jpg")
    }

    static let roots: [(FolderKind, String)] = [
        (.audiobooks, DropboxConfig.audiobooksPath),
        (.books, DropboxConfig.booksPath),
    ]
}
