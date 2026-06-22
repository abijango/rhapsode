import SwiftData
import SwiftUI
import UIKit

/// Minimal `UIApplicationDelegate` required to receive background `URLSession`
/// completion events. Without this the OS will not call the system's background-
/// session completion handler, and in-flight background downloads won't complete
/// after a cold relaunch.
///
/// Also hosts the `BGTaskScheduler` registration (moved from `RhapsodeApp.init`
/// so it is guaranteed to run before the first `UIApplicationDelegate` callback).
final class AppDelegate: NSObject, UIApplicationDelegate {

    // MARK: Shared container

    /// Set during `application(_:didFinishLaunchingWithOptions:)` — available to
    /// both the AppDelegate (for BackgroundDownloader) and `RhapsodeApp` (via the
    /// `@UIApplicationDelegateAdaptor` reference).
    private(set) var modelContainer: ModelContainer?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Register the BGTask handler before launch completes (system requirement).
        // The container is provided by RhapsodeApp after init; BackgroundRefresh.register
        // is called from RhapsodeApp.init which runs before the scene connects.
        return true
    }

    // MARK: Background URLSession events

    /// Store the OS-provided completion handler so it can be called once all
    /// background session events have been delivered to the delegate.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            // Not our session — let the system handle it.
            completionHandler()
            return
        }
        BackgroundDownloader.shared.backgroundSessionCompletionHandler = completionHandler
    }
}
