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
    /// App-lifetime audiobook player so playback survives navigation (tab switches,
    /// returning to the shelf) instead of being torn down with the player view.
    @State private var audioPlayer: AudiobookPlayer
    /// Global light/dark preference (Settings → Appearance). Applied at the root below.
    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue

    init() {
        // Ensure Application Support exists before SwiftData creates its store there
        // (it may be absent on a fresh install, which logs CoreData create-file errors).
        _ = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)

        let container: ModelContainer
        let schema = Schema(AppSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // The SwiftData store is a rebuildable cache (books re-download from Dropbox; progress
            // and stats re-pull from /.rhapsode-sync + UserDefaults). If it can't open — e.g. an
            // incompatible schema — delete and recreate rather than crashing on launch. This IS a
            // local data reset, so make it loud: a clean rename migration should never reach here.
            NSLog("⚠️ Rhapsode: ModelContainer failed to open — RECREATING STORE (local library/progress reset). Error: %@", String(describing: error))
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: config.url.path + suffix))
            }
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("Failed to create ModelContainer after store reset: \(error)")
            }
        }
        modelContainer = container
        // Share one DropboxSource between the library pipeline and progress sync so
        // token refresh stays serialized through a single actor.
        let dropbox = DropboxSource()
        let syncManager = SyncManager(
            source: dropbox,
            context: container.mainContext,
            progress: DropboxProgressSync(source: dropbox))
        _sync = State(initialValue: syncManager)
        // Register the background-refresh handler before launch completes.
        BackgroundRefresh.register(container: container)
        // Wire the container into BackgroundDownloader so its delegate callbacks
        // can reach SwiftData. Must happen before any background tasks fire.
        BackgroundDownloader.shared.container = container
        // When a freshly downloaded book finishes importing, re-pull cross-device
        // progress so a position pushed by another device applies right away.
        BackgroundDownloader.shared.onImportFinished = { [syncManager] in
            Task { await syncManager.pullAndMergeProgress() }
        }
        // WP-B: continuous push — when the app-lifetime player reports a position change
        // (throttled/forced inside the player), upload it cross-device. Wire the callback BEFORE
        // storing the player in @State (mirrors `_sync = State(initialValue:)` above) so the wired
        // instance is provably the one injected via `.environment(audioPlayer)`. Captures the same
        // syncManager instance so token refresh stays serialized through the one actor.
        let player = AudiobookPlayer()
        player.onProgressChanged = { [syncManager] key in
            Task { await syncManager.pushAudiobookProgress(sourcePath: key) }
        }
        _audioPlayer = State(initialValue: player)
        // WP-C: let SyncManager reconcile the live player when a newer remote position is
        // merged (auto-jump + prevents the player's cached position clobbering the merge).
        syncManager.audioPlayer = player
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
                } else if CommandLine.arguments.contains("-previewbookstats") {
                    BookStatsPreviewHarness()
                } else if CommandLine.arguments.contains("-previewplayer") {
                    PlayerPreviewHarness().environment(sync)
                } else {
                    RootTabView()
                        .environment(sync)
                        .environment(audioPlayer)
                        .task {
                            if PhaseZeroSelfTest.isRequested {
                                await PhaseZeroSelfTest.run(context: modelContainer.mainContext)
                            }
                            if LiveSmartSpeechSelfTest.isRequested {
                                await LiveSmartSpeechSelfTest.run()
                            }
                            if CommandLine.arguments.contains("-seedstats") {
                                Self.seedStats(context: modelContainer.mainContext)
                            }
                        }
                }
                #else
                RootTabView()
                    .environment(sync)
                    .environment(audioPlayer)
                #endif
            }
            .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        }
        .modelContainer(modelContainer)
#if targetEnvironment(macCatalyst)
        // MARK: Mac Catalyst — window sizing
        // .defaultSize sets the initial window size. Resizability is configured at
        // runtime in RootTabView via UIWindowScene.sizeRestrictions (see
        // configureCatalystWindow) since the right lever/timing on Catalyst is
        // scene-based, not a Scene modifier.
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

    #if DEBUG
    /// DEBUG-only: seed a few audiobooks with listened/saved stats so the Nerd Stats receipt can be
    /// previewed with data (launch arg `-seedstats`). Idempotent — skips if already seeded.
    @MainActor
    static func seedStats(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Audiobook>())) ?? []
        guard !existing.contains(where: { $0.sourcePath.hasPrefix("seed:") }) else { return }
        let seed: [(String, Double, Double)] = [
            ("Harry Potter and the Goblet of Fire (Full-Cast Edition)", 11_520, 1_440),
            ("Project Hail Mary", 6_000, 540),
            ("Dune", 3_120, 180),
            ("The Hobbit", 7_500, 840),
        ]
        for (title, played, saved) in seed {
            let b = Audiobook(title: title, sourcePath: "seed:\(title)")
            b.listenedSeconds = played
            b.smartSpeechSavedSeconds = saved
            context.insert(b)
        }
        try? context.save()
        SmartSpeechStats.totalPlayedSeconds = seed.reduce(0) { $0 + $1.1 }
        SmartSpeechStats.totalSavedSeconds = seed.reduce(0) { $0 + $1.2 }
    }
    #endif
}

