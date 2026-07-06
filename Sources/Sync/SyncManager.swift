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

    private var watcher: Task<Void, Never>?
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
    weak var activeReader: EbookReader?
    var activeReaderBookID: UUID?

    init(source: LibrarySource, context: ModelContext, progress: ProgressSync = NoopProgressSync()) {
        self.source = source
        self.context = context
        self.progress = progress
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
            await scanNow()
        }
        // Then pull any progress other devices wrote while we were away — the books
        // just imported above are now present to match against.
        await pullAndMergeProgress()
        // Back up our own lifetime SmartSpeech stats too (LWW skips if the remote is newer).
        await pushSmartSpeechStats()
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
        let p = PlaybackProgress(
            key: sourcePath, kind: .audiobooks,
            lastTrackIndex: book.lastTrackIndex, lastOffsetSeconds: book.lastOffsetSeconds,
            readingLocatorJSON: nil, listenedSeconds: book.listenedSeconds, updatedAt: updatedAt)
        do { try await progress.push(p) }
        catch {
            Self.log("pushAudiobookProgress failed: \(error.localizedDescription)")
            lastError = Self.progressSyncErrorMessage(error)
        }
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
            readingLocatorJSON: b.readingLocator, updatedAt: updatedAt)
        do { try await progress.push(p) }
        catch {
            Self.log("pushBookProgress failed: \(error.localizedDescription)")
            lastError = Self.progressSyncErrorMessage(error)
        }
    }

    /// User-facing message for a failed progress upload. The most common cause is a
    /// Dropbox token minted before the `files.content.write` scope was added — which
    /// fails silently and looks identical to "sync is broken" — so the message
    /// points the user at the reconnect that fixes it.
    private static func progressSyncErrorMessage(_ error: Error) -> String {
        "Couldn’t sync progress to Dropbox. If you connected before progress sync "
        + "was enabled, disconnect and reconnect Dropbox in Settings on both devices. "
        + "(\(error))"
    }

    /// Pull every remote progress record and apply each to the matching local
    /// model iff the remote is newer (last-writer-wins). Safe to call on launch /
    /// foreground; a missing sync folder or no write scope simply yields nothing.
    func pullAndMergeProgress() async {
        if let remotes = try? await progress.pullAll(), !remotes.isEmpty {
            for p in remotes { applyRemoteProgress(p) }
            try? context.save()
            Self.log("pulled \(remotes.count) progress record(s)")
        }
        await pullSmartSpeechStats()
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

    /// Apply one remote record to its matching local model when it wins LWW.
    /// Match is by the stable container-relative key (`sourcePath` / `fileRelPath`).
    private func applyRemoteProgress(_ p: PlaybackProgress) {
        switch p.kind {
        case .audiobooks:
            guard let book = (try? context.fetch(FetchDescriptor<Audiobook>()))?
                .first(where: { $0.sourcePath == p.key }) else { return }
            // WP8: listenedSeconds is a monotonic cumulative counter — merge with max regardless of the
            // position LWW guard, so a stale-position remote can't clobber a higher local listened total.
            if let remoteListened = p.listenedSeconds {
                book.listenedSeconds = max(book.listenedSeconds ?? 0, remoteListened)
            }
            guard p.isNewer(than: book.progressUpdatedAt) else { return }
            book.lastTrackIndex = p.lastTrackIndex
            book.lastOffsetSeconds = p.lastOffsetSeconds
            book.progressUpdatedAt = p.updatedAt
            // WP-C: if the app-lifetime player holds this book, reconcile its in-memory
            // position to the merged value (auto-jump + prevents the player from later
            // clobbering the merge with its stale cached position). No-op (anti-echo)
            // inside the player: it does NOT re-stamp or re-push the applied position.
            audioPlayer?.applyRemotePosition(
                bookID: book.id, trackIndex: p.lastTrackIndex, offsetSeconds: p.lastOffsetSeconds)
        case .books:
            guard let b = (try? context.fetch(FetchDescriptor<Book>()))?
                .first(where: { $0.fileRelPath == p.key }),
                  p.isNewer(than: b.progressUpdatedAt) else { return }
            b.readingLocator = p.readingLocatorJSON
            b.progressUpdatedAt = p.updatedAt
            // WP-C: if this book is open in the reader, auto-jump it to the merged locator.
            // EbookReader decodes the JSON itself (keeps Readium out of SyncManager).
            if activeReaderBookID == b.id, let json = p.readingLocatorJSON {
                activeReader?.applyRemoteLocator(json: json)
            }
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
        var cursor: String?
        while !Task.isCancelled {
            do {
                if cursor == nil {
                    cursor = try await source.latestCursor(DropboxProgressSync.folder)
                }
                guard let c = cursor else { return }
                let hasChanges = try await source.longpoll(cursor: c)
                if Task.isCancelled { return }
                if hasChanges {
                    let (_, newCursor) = try await source.changes(since: c)
                    cursor = newCursor
                    await pullAndMergeProgress()
                }
            } catch {
                // Folder missing (no push yet) or transient error — re-seed + back off.
                Self.log("watchProgress error: \(error) — backing off")
                cursor = nil
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Longpoll one folder until cancelled, ingesting new entries as they appear.
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
                    let (entries, newCursor) = try await source.changes(since: cursor)
                    guard let folder = self[folderID] else { return }
                    folder.cursor = newCursor
                    try? context.save()
                    let jobs = entries.filter { Self.belongs($0, to: kind) }.map { ($0, kind) }
                    Self.log("changes \(kind) → \(entries.count) entries, \(jobs.count) to ingest")
                    await ingest(jobs)
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

    // MARK: Manual scan

    /// List both roots and download/import anything new. The reliable fallback.
    func scanNow() async {
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

    /// Feed jobs discovered by the watcher / background refresh into the queue.
    func ingest(_ jobs: [(entry: RemoteEntry, kind: FolderKind)]) async {
        for job in jobs { await process(job.entry, kind: job.kind) }
    }

    /// One-shot delta check (no longpoll) for `BGTaskScheduler` background refresh.
    /// Pulls changes since each folder's cursor, enqueues new files into the
    /// background `URLSession`, and returns quickly — the OS continues the actual
    /// transfers outside the refresh window.
    func backgroundDeltaCheck() async {
        do { try await source.authenticate() } catch { return }
        let folders = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
        for folder in folders {
            guard let cursor = folder.cursor else { continue }
            do {
                let (entries, newCursor) = try await source.changes(since: cursor)
                folder.cursor = newCursor
                try? context.save()
                let kind = folder.kind
                // Enqueue via process() — which now routes single Dropbox files to
                // BackgroundDownloader and returns immediately.
                await ingest(entries.filter { Self.belongs($0, to: kind) }.map { ($0, kind) })
            } catch {
                continue
            }
        }
        // WP-C: also pull cross-device progress so the shelf % / resume position refresh
        // opportunistically while the app is suspended (OS-gated best-effort).
        await pullAndMergeProgress()
    }

    /// Ask for notification permission (call once, e.g. after connecting).
    func requestNotificationPermission() async {
        await notifier.requestAuthorization()
    }

    // MARK: One item: dedup → download → import → notify

    private func process(_ entry: RemoteEntry, kind: FolderKind) async {
        guard Self.isAcceptable(entry, kind: kind) else { return }
        let rel = relPath(for: entry, kind: kind)
        guard !isAlreadyImported(rel: rel, kind: kind),
              !isInFlight(remoteEntryID: entry.id) else { return }

        let item = DownloadItem(remoteEntryID: entry.id, title: entry.name, kind: kind,
                                state: .downloading, totalBytes: entry.size)
        context.insert(item)
        try? context.save()
        await notifier.notifyDownloadStarted(title: entry.name)

        // Route single files to the background URLSession when backed by DropboxSource;
        // fall back to inline foreground transfer for MockLibrarySource (tests, debug).
        // Folders are always downloaded inline (3b is deferred).
        if let dbx = source as? DropboxSource, !entry.isFolder {
            do {
                let req = try await dbx.downloadRequest(for: entry.path)
                BackgroundDownloader.shared.enqueue(request: req, item: item, destRelPath: rel)
                // The BackgroundDownloader delegate will set .done / .failed + notify.
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to enqueue \(entry.name): \(error.localizedDescription)"
            }
        } else {
            do {
                let dest = try ContainerPaths.url(forRelativePath: rel)
                try await transfer(entry, to: dest)
                try await importItem(at: dest, kind: kind)
                item.bytesReceived = item.totalBytes
                item.state = .done
                try? context.save()
                await notifier.notifyDownloadFinished(title: entry.name)
            } catch {
                item.state = .failed
                try? context.save()
                lastError = "Failed to download \(entry.name): \(error.localizedDescription)"
            }
        }
    }

    /// Foreground transfer — used by MockLibrarySource (tests) and folder entries.
    private func transfer(_ entry: RemoteEntry, to destination: URL) async throws {
        try await source.download(entry, to: destination)
    }

    private func importItem(at dest: URL, kind: FolderKind) async throws {
        switch kind {
        case .audiobooks:
            let audiobook = try await AudiobookImporter.makeAudiobook(fromLocal: dest)
            context.insert(audiobook)
            try context.save()
            // Playback is LIVE silence-trimming now; no auto batch-render on import (it would
            // produce a .m4a nothing plays). Batch rendering is on-demand from Settings (WP5).
        case .books:
            context.insert(try await EbookImporter.makeBook(fromLocal: dest))
            try context.save()
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

    private func relPath(for entry: RemoteEntry, kind: FolderKind) -> String {
        (kind == .audiobooks ? "Audiobooks/" : "Books/") + entry.name
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

    static let roots: [(FolderKind, String)] = [
        (.audiobooks, DropboxConfig.audiobooksPath),
        (.books, DropboxConfig.booksPath),
    ]
}
