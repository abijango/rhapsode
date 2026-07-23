@preconcurrency import BackgroundTasks
import Foundation
import SwiftData

/// `BGTaskScheduler` background-detect (Phase 2 fast-follow): while the app is
/// closed, periodically delta-check the active library backend and download new
/// files. The OS decides when to run this; we only ask. Not verifiable in the
/// simulator — test on device via the Xcode debugger's
/// `_simulateLaunchForTaskWithIdentifier:` command.
enum BackgroundRefresh {
    static let taskID = "com.naufalmir.rhapsode.refresh"

    /// Builds a `SyncManager` for the active library backend. Set via `register` at launch
    /// (e.g. from `RhapsodeApp`) so background refresh uses the same source + progress sync
    /// as the foreground app — not a hardcoded Dropbox stub.
    @MainActor
    private static var makeSyncManager: @MainActor (ModelContainer) -> SyncManager = { container in
        SyncManager(source: DropboxSource(), context: container.mainContext)
    }

    /// Register the launch handler. Must be called during launch (App.init),
    /// before the app finishes launching.
    ///
    /// - Parameters:
    ///   - container: SwiftData container for background work.
    ///   - makeSyncManager: Optional factory matching `RhapsodeApp`'s backend wiring
    ///     (SMB / server / Dropbox + progress sync). When omitted, the last registered
    ///     factory (or Dropbox default) is used.
    @MainActor
    static func register(
        container: ModelContainer,
        makeSyncManager factory: (@MainActor (ModelContainer) -> SyncManager)? = nil
    ) {
        if let factory {
            Self.makeSyncManager = factory
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule() // chain the next opportunity
            let work = Task { @MainActor in
                let sync = Self.makeSyncManager(container)
                await sync.backgroundDeltaCheck()
                refresh.setTaskCompleted(success: true)
            }
            refresh.expirationHandler = { work.cancel() }
        }
    }

    /// Ask the OS to run a refresh no sooner than ~15 minutes from now.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
