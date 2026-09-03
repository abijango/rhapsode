import Foundation
import SwiftData

/// Background `URLSession` download manager (Phase 3a + 3b).
///
/// Uses `URLSessionConfiguration.background(...)` so the OS continues transfers
/// when the app is suspended and can relaunch the app to deliver completions.
/// The singleton is recreated at launch with the SAME session identifier so any
/// in-flight tasks reattach to this delegate automatically.
///
/// Phase 3b: MP3-folder audiobooks enqueue one background task per child file,
/// sharing a `groupID`. When every child reaches `.done`, the folder is imported
/// once (not per-file).
///
/// Thread-safety contract:
///   • `URLSessionDownloadDelegate` methods fire on an arbitrary serial queue
///     provided by URLSession. File-system work (moving the temp file) is done
///     there synchronously — the temp file is deleted when the callback returns,
///     so it MUST be moved before hopping actors.
///   • SwiftData / model writes hop to `@MainActor` via `Task { @MainActor in }`.
///     NEVER use `MainActor.assumeIsolated` (trips a dispatch-queue assertion).
@MainActor
final class BackgroundDownloader: NSObject {
    static let sessionIdentifier = "com.naufalmir.rhapsode.bg-downloads"

    // MARK: Shared instance

    /// The app-global singleton. Configured with a container at launch.
    static let shared = BackgroundDownloader()

    // MARK: State

    /// Set at launch by AppDelegate / RhapsodeApp so delegate callbacks can reach SwiftData.
    var container: ModelContainer?

    /// Stored by AppDelegate's `application(_:handleEventsForBackgroundURLSession:completionHandler:)`;
    /// invoked in `urlSessionDidFinishEvents(forBackgroundURLSession:)`.
    var backgroundSessionCompletionHandler: (() -> Void)?

    /// Invoked on the main actor after a download finishes importing into the
    /// library. Wired by the app to re-pull cross-device progress, so a position
    /// another device pushed is applied as soon as the matching book lands (rather
    /// than only on the next foreground). Optional — unset in tests.
    var onImportFinished: (@MainActor () -> Void)?

    /// Invoked when a download reaches a terminal state or leaves the queue so
    /// `SyncManager` can refresh its in-flight ID set without shelf `@Query`s.
    var onDownloadQueueChanged: (@MainActor () -> Void)?

    /// Fast lookup from `DownloadItem.id` → SwiftData persistent ID. Populated on
    /// enqueue and rebuilt on launch for in-flight rows; avoids a full-table fetch on
    /// every `URLSession` progress callback.
    private var downloadItemIDs: [UUID: PersistentIdentifier] = [:]
    /// Throttle UI progress updates (bytesReceived) to ~350ms per item.
    private var lastProgressUpdate: [UUID: Date] = [:]
    private static let progressUpdateInterval: TimeInterval = 0.35

    // MARK: Session (created lazily, once)

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Allow up to 4 simultaneous background downloads.
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: Item lookup

    /// Register a newly enqueued item so delegate callbacks can resolve it without scanning the store.
    func registerDownloadItem(_ item: DownloadItem) {
        downloadItemIDs[item.id] = item.persistentModelID
    }

    private func unregisterDownloadItem(id: UUID) {
        downloadItemIDs.removeValue(forKey: id)
        lastProgressUpdate.removeValue(forKey: id)
    }

    /// Reattach in-flight rows after relaunch (map is empty until enqueue / reconcile).
    private func rebuildDownloadItemMap(ctx: ModelContext) {
        let active = (try? ctx.fetch(FetchDescriptor<DownloadItem>()))?
            .filter { $0.state == .pending || $0.state == .downloading } ?? []
        for item in active {
            downloadItemIDs[item.id] = item.persistentModelID
        }
    }

    // MARK: Enqueue

    /// Bake a fresh access token into a `URLRequest` and hand the task to the OS.
    func enqueue(request: URLRequest, item: DownloadItem, destRelPath: String, groupTitle: String? = nil) {
        enqueue(request: request, payload: TaskPayload(
            itemID: item.id,
            destRelPath: destRelPath,
            kind: item.kind,
            title: item.title ?? "",
            groupID: item.groupID,
            groupFolderRelPath: item.groupFolderRelPath,
            groupTitle: groupTitle
        ))
    }

    /// Enqueue with a prebuilt payload.
    func enqueue(request: URLRequest, payload: TaskPayload) {
        guard let encoded = try? JSONEncoder().encode(payload),
              let description = String(data: encoded, encoding: .utf8)
        else { return }
        let task = session.downloadTask(with: request)
        task.taskDescription = description
        task.resume()
    }

    // MARK: Launch reconciliation

    /// On launch, find any `DownloadItem` stuck in `.downloading` that has no live
    /// background task (i.e. the task was lost when the app was killed mid-download)
    /// and mark it `.failed` so the UI doesn't show it as stuck.
    func reconcileOnLaunch() {
        guard let container else { return }
        session.getAllTasks { tasks in
            let liveTaskIDs: Set<UUID> = Set(
                tasks.compactMap { $0.taskDescription }
                     .compactMap { try? JSONDecoder().decode(TaskPayload.self, from: Data($0.utf8)) }
                     .map(\.itemID)
            )
            Task { @MainActor in
                let ctx = container.mainContext
                self.rebuildDownloadItemMap(ctx: ctx)
                // Fetch all items and filter in-memory; #Predicate cannot compare enum cases.
                let all = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
                let downloading = all.filter { $0.state == .downloading }

                let toFail = Self.orphanedItems(downloading: downloading, liveTaskIDs: liveTaskIDs)
                for item in toFail { item.state = .failed }
                if !toFail.isEmpty { try? ctx.save() }
            }
        }
    }

    /// Pure function: given the set of downloading items and live task IDs, return
    /// the items whose IDs are absent from `liveTaskIDs` (orphaned by a kill).
    static func orphanedItems(
        downloading: [DownloadItem],
        liveTaskIDs: Set<UUID>
    ) -> [DownloadItem] {
        downloading.filter { !liveTaskIDs.contains($0.id) }
    }

    /// True when every member of `groupID` is `.done` and none are `.failed`.
    /// Extracted for headless self-test coverage.
    static func shouldImportGroup(items: [DownloadItem], groupID: String) -> Bool {
        let members = items.filter { $0.groupID == groupID }
        guard !members.isEmpty else { return false }
        if members.contains(where: { $0.state == .failed }) { return false }
        return members.allSatisfy { $0.state == .done }
    }

    // MARK: Group import (Phase 3b)

    @MainActor
    private func tryImportGroupIfComplete(
        groupID: String,
        folderRel: String,
        groupTitle: String,
        kind: FolderKind,
        ctx: ModelContext
    ) async {
        let all = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        guard Self.shouldImportGroup(items: all, groupID: groupID) else { return }

        // Another completion may have imported already — skip if the shelf has it.
        if isFolderAlreadyImported(folderRel: folderRel, kind: kind, ctx: ctx) { return }

        guard let folderURL = try? ContainerPaths.url(forRelativePath: folderRel) else { return }

        do {
            switch kind {
            case .audiobooks:
                let audiobook = try await AudiobookImporter.makeAudiobook(fromLocal: folderURL)
                ctx.insert(audiobook)
            case .books:
                return // folder groups are audiobook-only
            }
            try ctx.save()
            removeGroupItems(groupID: groupID, ctx: ctx)
            onImportFinished?()
            notifyDownloadQueueChanged()

            let notifier = NotificationService()
            await notifier.notifyDownloadFinished(title: groupTitle)
        } catch {
            for item in all where item.groupID == groupID { item.state = .failed }
            try? ctx.save()
            notifyDownloadQueueChanged()
            SyncManager.log("group import failed for \(folderRel): \(error)")
        }
    }

    @MainActor
    private func removeGroupItems(groupID: String, ctx: ModelContext) {
        let all = (try? ctx.fetch(FetchDescriptor<DownloadItem>())) ?? []
        for item in all where item.groupID == groupID {
            ctx.delete(item)
        }
        try? ctx.save()
        notifyDownloadQueueChanged()
    }

    @MainActor
    private func removeItem(id: UUID, ctx: ModelContext) {
        if let item = findItem(id: id, ctx: ctx) {
            ctx.delete(item)
            try? ctx.save()
        }
        unregisterDownloadItem(id: id)
        notifyDownloadQueueChanged()
    }

    @MainActor
    private func isFolderAlreadyImported(folderRel: String, kind: FolderKind, ctx: ModelContext) -> Bool {
        switch kind {
        case .audiobooks:
            return (try? ctx.fetch(FetchDescriptor<Audiobook>()))?
                .contains { $0.sourcePath == folderRel } ?? false
        case .books:
            return (try? ctx.fetch(FetchDescriptor<Book>()))?
                .contains { $0.fileRelPath == folderRel } ?? false
        }
    }

    @MainActor
    private func importSingleFile(at destURL: URL, kind: FolderKind, ctx: ModelContext) async throws {
        switch kind {
        case .audiobooks:
            let audiobook = try await AudiobookImporter.makeAudiobook(fromLocal: destURL)
            ctx.insert(audiobook)
        case .books:
            ctx.insert(try await EbookImporter.makeBook(fromLocal: destURL))
        }
        try ctx.save()
    }

    @MainActor
    private func notifyDownloadQueueChanged() {
        onDownloadQueueChanged?()
    }

    @MainActor
    private func markItemFailed(id: UUID, ctx: ModelContext) {
        if let item = findItem(id: id, ctx: ctx) {
            item.state = .failed
            try? ctx.save()
        }
        notifyDownloadQueueChanged()
    }

    @MainActor
    private func markItemDone(id: UUID, ctx: ModelContext) {
        if let item = findItem(id: id, ctx: ctx) {
            if item.totalBytes > 0 { item.bytesReceived = item.totalBytes }
            item.state = .done
            try? ctx.save()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloader: URLSessionDownloadDelegate {

    /// Called when a download task finishes writing to a temporary file.
    /// IMPORTANT: the temp file at `location` is deleted when this method returns.
    /// Move it synchronously, THEN hop to MainActor for SwiftData work.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TaskPayload.self, from: data)
        else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            Task { @MainActor in
                guard let ctx = self.container?.mainContext else { return }
                self.markItemFailed(id: payload.itemID, ctx: ctx)
            }
            return
        }

        guard let destURL = try? ContainerPaths.url(forRelativePath: payload.destRelPath) else {
            Task { @MainActor in
                guard let ctx = self.container?.mainContext else { return }
                self.markItemFailed(id: payload.itemID, ctx: ctx)
            }
            return
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: destURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.moveItem(at: location, to: destURL)
        } catch {
            Task { @MainActor in
                guard let ctx = self.container?.mainContext else { return }
                self.markItemFailed(id: payload.itemID, ctx: ctx)
            }
            return
        }

        let kind = payload.kind
        let title = payload.title
        Task { @MainActor in
            guard let ctx = self.container?.mainContext else { return }
            self.markItemDone(id: payload.itemID, ctx: ctx)

            if let groupID = payload.groupID, let folderRel = payload.groupFolderRelPath {
                let groupTitle = payload.groupTitle ?? title
                await self.tryImportGroupIfComplete(
                    groupID: groupID,
                    folderRel: folderRel,
                    groupTitle: groupTitle,
                    kind: kind,
                    ctx: ctx
                )
            } else {
                do {
                    try await self.importSingleFile(at: destURL, kind: kind, ctx: ctx)
                    self.removeItem(id: payload.itemID, ctx: ctx)
                    self.onImportFinished?()

                    let notifier = NotificationService()
                    await notifier.notifyDownloadFinished(title: title)
                } catch {
                    self.markItemFailed(id: payload.itemID, ctx: ctx)
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TaskPayload.self, from: data)
        else { return }

        Task { @MainActor in
            guard let ctx = self.container?.mainContext else { return }
            let now = Date()
            if let last = self.lastProgressUpdate[payload.itemID],
               now.timeIntervalSince(last) < Self.progressUpdateInterval {
                return
            }
            self.lastProgressUpdate[payload.itemID] = now
            if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                item.bytesReceived = totalBytesWritten
                if totalBytesExpectedToWrite > 0 {
                    item.totalBytes = totalBytesExpectedToWrite
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return }

        guard let description = task.taskDescription,
              let data = description.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TaskPayload.self, from: data)
        else { return }

        Task { @MainActor in
            guard let ctx = self.container?.mainContext else { return }
            self.markItemFailed(id: payload.itemID, ctx: ctx)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let handler = self.backgroundSessionCompletionHandler {
                self.backgroundSessionCompletionHandler = nil
                handler()
            }
        }
    }

    @MainActor
    private func findItem(id: UUID, ctx: ModelContext) -> DownloadItem? {
        if let pid = downloadItemIDs[id] {
            if let item = ctx.model(for: pid) as? DownloadItem {
                return item
            }
            downloadItemIDs.removeValue(forKey: id)
        }
        let targetID = id
        var descriptor = FetchDescriptor<DownloadItem>(
            predicate: #Predicate<DownloadItem> { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        if let item = try? ctx.fetch(descriptor).first {
            downloadItemIDs[id] = item.persistentModelID
            return item
        }
        return nil
    }
}

// MARK: - Task payload

/// Persisted in `URLSessionDownloadTask.taskDescription` (JSON-encoded) so the
/// mapping from task → `DownloadItem` survives the app being killed mid-download.
struct TaskPayload: Codable, Sendable {
    let itemID: UUID
    let destRelPath: String
    let kind: FolderKind
    let title: String
    /// Phase 3b: set when this task is one file in an MP3-folder group.
    let groupID: String?
    /// Phase 3b: container-relative folder to import when the group completes.
    let groupFolderRelPath: String?
    /// Phase 3b: human-readable folder name for the finished notification.
    let groupTitle: String?

    init(
        itemID: UUID,
        destRelPath: String,
        kind: FolderKind,
        title: String,
        groupID: String? = nil,
        groupFolderRelPath: String? = nil,
        groupTitle: String? = nil
    ) {
        self.itemID = itemID
        self.destRelPath = destRelPath
        self.kind = kind
        self.title = title
        self.groupID = groupID
        self.groupFolderRelPath = groupFolderRelPath
        self.groupTitle = groupTitle
    }
}