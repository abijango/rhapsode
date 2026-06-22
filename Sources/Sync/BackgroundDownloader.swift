import Foundation
import SwiftData

/// Background `URLSession` download manager (Phase 3a).
///
/// Uses `URLSessionConfiguration.background(...)` so the OS continues transfers
/// when the app is suspended and can relaunch the app to deliver completions.
/// The singleton is recreated at launch with the SAME session identifier so any
/// in-flight tasks reattach to this delegate automatically.
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

    // MARK: Session (created lazily, once)

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Allow up to 4 simultaneous background downloads.
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // MARK: Enqueue

    /// Bake a fresh access token into a `URLRequest` and hand the task to the OS.
    ///
    /// - Parameters:
    ///   - request: A fully formed request from `DropboxSource.downloadRequest(for:)`.
    ///   - item:    The already-inserted `DownloadItem` (state = .downloading).
    ///   - destRelPath: Container-relative destination (e.g. "Books/novel.epub").
    func enqueue(request: URLRequest, item: DownloadItem, destRelPath: String) {
        let payload = TaskPayload(
            itemID: item.id,
            destRelPath: destRelPath,
            kind: item.kind,
            title: item.title ?? ""
        )
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
    ///
    /// The matching logic is extracted into a pure static function so it can be
    /// unit-tested without touching the live session.
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
    /// Extracted so the self-test can verify the decision logic without a live session.
    static func orphanedItems(
        downloading: [DownloadItem],
        liveTaskIDs: Set<UUID>
    ) -> [DownloadItem] {
        downloading.filter { !liveTaskIDs.contains($0.id) }
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
        // Decode the payload baked in at enqueue time.
        guard let description = downloadTask.taskDescription,
              let data = description.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TaskPayload.self, from: data)
        else { return }

        // Check HTTP status — Dropbox returns 401/409 as "successful" downloads of
        // an error body. Treat non-2xx as failure.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            let status = http.statusCode
            Task { @MainActor in
                guard let ctx = self.container?.mainContext else { return }
                if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                    if status == 401 {
                        // Token expired after a long suspension: mark failed so the
                        // UI shows it; the user can re-trigger via Scan Now.
                        item.state = .failed
                    } else {
                        item.state = .failed
                    }
                    try? ctx.save()
                }
            }
            return
        }

        // Resolve the destination URL now, still on the delegate queue.
        guard let destURL = try? ContainerPaths.url(forRelativePath: payload.destRelPath) else {
            Task { @MainActor in
                guard let ctx = self.container?.mainContext else { return }
                if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                    item.state = .failed
                    try? ctx.save()
                }
            }
            return
        }

        // Move the temp file synchronously before this callback returns.
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
                if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                    item.state = .failed
                    try? ctx.save()
                }
            }
            return
        }

        // Hop to MainActor for import + SwiftData updates.
        let kind = payload.kind
        let title = payload.title
        Task { @MainActor in
            guard let ctx = self.container?.mainContext else { return }
            do {
                var newAudiobookID: UUID?
                switch kind {
                case .audiobooks:
                    let audiobook = try await AudiobookImporter.makeAudiobook(fromLocal: destURL)
                    ctx.insert(audiobook)
                    newAudiobookID = audiobook.id
                case .books:
                    ctx.insert(try await EbookImporter.makeBook(fromLocal: destURL))
                }
                try ctx.save()

                if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                    item.bytesReceived = item.totalBytes
                    item.state = .done
                    try? ctx.save()
                }

                // Cadence: render-on-download (WP4). No-op unless the feature is enabled.
                if let bookID = newAudiobookID {
                    Task { await CadenceRenderCoordinator.shared.enqueue(bookID: bookID) }
                }

                let notifier = NotificationService()
                await notifier.notifyDownloadFinished(title: title)
            } catch {
                if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                    item.state = .failed
                    try? ctx.save()
                }
            }
        }
    }

    /// Called periodically with progress updates.
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
            if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                item.bytesReceived = totalBytesWritten
                if totalBytesExpectedToWrite > 0 {
                    item.totalBytes = totalBytesExpectedToWrite
                }
                // No explicit save: SwiftData observes @Model changes automatically.
            }
        }
    }

    /// Called when a task completes (successfully or not). For network-level errors
    /// (no connection, timeout): mark failed. Success is handled in
    /// `didFinishDownloadingTo`, so only act when error != nil.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error != nil else { return } // success path handled in didFinishDownloadingTo

        guard let description = task.taskDescription,
              let data = description.data(using: .utf8),
              let payload = try? JSONDecoder().decode(TaskPayload.self, from: data)
        else { return }

        Task { @MainActor in
            guard let ctx = self.container?.mainContext else { return }
            if let item = self.findItem(id: payload.itemID, ctx: ctx) {
                item.state = .failed
                try? ctx.save()
            }
        }
    }

    /// Called by the system when all queued background events for this session have
    /// been delivered. Invoke the stored completion handler on the main thread.
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            if let handler = self.backgroundSessionCompletionHandler {
                self.backgroundSessionCompletionHandler = nil
                handler()
            }
        }
    }

    // MARK: Helpers

    @MainActor
    private func findItem(id: UUID, ctx: ModelContext) -> DownloadItem? {
        (try? ctx.fetch(FetchDescriptor<DownloadItem>()))?.first { $0.id == id }
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
}
