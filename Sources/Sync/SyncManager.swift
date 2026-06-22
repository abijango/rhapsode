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

    private(set) var isScanning = false
    var lastError: String?

    private var watcher: Task<Void, Never>?

    init(source: LibrarySource, context: ModelContext) {
        self.source = source
        self.context = context
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
    }

    private func watchLoop() async {
        await withTaskGroup(of: Void.self) { group in
            let folders = (try? context.fetch(FetchDescriptor<WatchedFolder>())) ?? []
            for folder in folders {
                let id = folder.persistentModelID
                group.addTask { await self.watch(folderID: id) }
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

    private subscript(id: PersistentIdentifier) -> WatchedFolder? {
        context.model(for: id) as? WatchedFolder
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
            context.insert(try await AudiobookImporter.makeAudiobook(fromLocal: dest))
        case .books:
            context.insert(try await EbookImporter.makeBook(fromLocal: dest))
        }
        try context.save()
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
