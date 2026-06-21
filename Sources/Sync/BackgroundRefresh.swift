@preconcurrency import BackgroundTasks
import Foundation
import SwiftData

/// `BGTaskScheduler` background-detect (Phase 2 fast-follow): while the app is
/// closed, periodically delta-check Dropbox and download new files. The OS decides
/// when to run this; we only ask. Not verifiable in the simulator — test on device
/// via the Xcode debugger's `_simulateLaunchForTaskWithIdentifier:` command.
enum BackgroundRefresh {
    static let taskID = "com.naufalmir.rhapsode.refresh"

    /// Register the launch handler. Must be called during launch (App.init),
    /// before the app finishes launching.
    static func register(container: ModelContainer) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            schedule() // chain the next opportunity
            let work = Task { @MainActor in
                let sync = SyncManager(source: DropboxSource(), context: container.mainContext)
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
