import SwiftData
import SwiftUI

@main
struct RhapsodeApp: App {
    /// Wires up the minimal `UIApplicationDelegate` needed for background URLSession
    /// completion events (`handleEventsForBackgroundURLSession`).
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Single container registering the whole model set (see `AppSchema`).
    let modelContainer: ModelContainer
    /// App-wide sync/download pipeline, observed by the shelves + downloads UI.
    @State private var sync: SyncManager

    init() {
        // Ensure Application Support exists before SwiftData creates its store there
        // (it may be absent on a fresh install, which logs CoreData create-file errors).
        _ = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)

        let container: ModelContainer
        do {
            let schema = Schema(AppSchema.models)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        modelContainer = container
        // Share one DropboxSource between the library pipeline and progress sync so
        // token refresh stays serialized through a single actor.
        let dropbox = DropboxSource()
        _sync = State(initialValue: SyncManager(
            source: dropbox,
            context: container.mainContext,
            progress: DropboxProgressSync(source: dropbox)))
        // Register the background-refresh handler before launch completes.
        BackgroundRefresh.register(container: container)
        // Wire the container into BackgroundDownloader so its delegate callbacks
        // can reach SwiftData. Must happen before any background tasks fire.
        BackgroundDownloader.shared.container = container
        // Show download notifications even while the app is in the foreground.
        NotificationPresenter.install()
        // Reconcile any downloads that were in-flight when the app was last killed.
        BackgroundDownloader.shared.reconcileOnLaunch()
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if CommandLine.arguments.contains("-readerscreenshot") {
                DebugReaderHarness()
            } else {
                RootTabView()
                    .environment(sync)
                    .task {
                        if PhaseZeroSelfTest.isRequested {
                            await PhaseZeroSelfTest.run(context: modelContainer.mainContext)
                        }
                    }
            }
            #else
            RootTabView()
                .environment(sync)
            #endif
        }
        .modelContainer(modelContainer)
#if targetEnvironment(macCatalyst)
        // MARK: Mac Catalyst — window sizing
        // Give the window a comfortable default size when first opened on macOS.
        // .automatic lets the user freely resize; .contentSize would pin the window
        // to its content's ideal size and can over-constrain a navigation/split UI.
        .defaultSize(width: 1_000, height: 720)
        .windowResizability(.automatic)
        // MARK: Mac Catalyst — menu-bar commands
        .commands {
            // Remove the "New Window" item — this app is a single-library browser
            // and a second window adds no meaningful value for now.
            CommandGroup(replacing: .newItem) { }

            // Library menu: manual Scan Now accessible from the menu bar.
            // scanNow() is @MainActor and guards against double-runs internally.
            // NOTE: Player/reader commands (play-pause, page-turn) are intentionally
            // omitted — driving AudiobookPlayer/EbookReader from menu items requires
            // @FocusedValue bindings injected in PlayerView/ReaderView, which are
            // not owned by this file. Left as future work.
            CommandMenu("Library") {
                Button("Scan Now") {
                    Task { @MainActor in await sync.scanNow() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
#endif
    }
}
