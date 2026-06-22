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
            Group {
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
            // Make the Mac Catalyst window freely resizable (no-op elsewhere).
            .modifier(CatalystWindowSizing())
        }
        .modelContainer(modelContainer)
#if targetEnvironment(macCatalyst)
        // MARK: Mac Catalyst — window sizing
        // .defaultSize sets the initial window size. NOTE: SwiftUI's
        // `.windowResizability` is an AppKit-backed API that is NOT honored on Mac
        // Catalyst — resizability there is governed by `UIWindowScene.sizeRestrictions`,
        // which `CatalystWindowSizing` (applied to the window content) sets explicitly.
        .defaultSize(width: 1_000, height: 720)
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

/// Makes the Mac Catalyst window freely resizable. `.windowResizability` (AppKit)
/// is ignored on Catalyst, so we reach the `UIWindowScene` and widen its
/// `sizeRestrictions` directly. A no-op on iOS/iPadOS.
private struct CatalystWindowSizing: ViewModifier {
    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content.background(CatalystWindowConfigurator())
        #else
        content
        #endif
    }
}

#if targetEnvironment(macCatalyst)
/// Sets the host `UIWindowScene`'s size restrictions once the view is in the
/// window hierarchy: a sane minimum and an unbounded maximum (min < max ⇒
/// resizable; the default can leave the window pinned).
private struct CatalystWindowConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { ConfiguringView() }
    func updateUIView(_ uiView: UIView, context: Context) {}

    final class ConfiguringView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let restrictions = window?.windowScene?.sizeRestrictions else { return }
            restrictions.minimumSize = CGSize(width: 600, height: 480)
            restrictions.maximumSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        }
    }
}
#endif
