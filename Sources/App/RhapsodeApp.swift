import SwiftData
import SwiftUI

@main
struct RhapsodeApp: App {
    private static let didResetStoreKey = "didResetStore"
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
            // Only attempt one automatic wipe per install; back up the store files first.
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: Self.didResetStoreKey) {
                fatalError("ModelContainer failed to open after a prior store reset: \(error)")
            }
            NSLog("⚠️ Rhapsode: ModelContainer failed to open — backing up store and RECREATING (local library/progress reset). Error: %@", String(describing: error))
            Self.backupStoreFiles(at: config.url)
            defaults.set(true, forKey: Self.didResetStoreKey)
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
        let syncManager = Self.makeSyncManager(container: container)
        _sync = State(initialValue: syncManager)
        // Register the background-refresh handler before launch completes.
        BackgroundRefresh.register(container: container, makeSyncManager: Self.makeSyncManager)
        // Wire the container into BackgroundDownloader so its delegate callbacks
        // can reach SwiftData. Must happen before any background tasks fire.
        BackgroundDownloader.shared.container = container
        // When a freshly downloaded book finishes importing, re-pull cross-device
        // progress so a position pushed by another device applies right away.
        BackgroundDownloader.shared.onImportFinished = { [syncManager] in
            syncManager.invalidateOnDeviceCatalogCache()
            Task { await syncManager.pullAndMergeProgress() }
        }
        BackgroundDownloader.shared.onDownloadQueueChanged = { [syncManager] in
            syncManager.refreshDownloadingRemoteEntryIDs()
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
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-readerscreenshot") {
                    DebugReaderHarness()
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
        .defaultSize(width: 1_440, height: 900)
        // MARK: Mac Catalyst — menu-bar commands
        .commands {
            // Remove the "New Window" item — this app is a single-library browser
            // and a second window adds no meaningful value for now.
            CommandGroup(replacing: .newItem) { }

            // Library menu: manual Scan Now accessible from the menu bar.
            // scanNow() is @MainActor and guards against double-runs internally.
            // Playback menu: play/pause/skip via @FocusedValue from PlayerView.
            CommandMenu("Library") {
                Button("Scan Now") {
                    Task { @MainActor in await sync.scanNow() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            PlaybackCommands()
        }
#endif
    }

    /// Copy the SwiftData store (and WAL/SHM sidecars) to Application Support before a recovery wipe.
    private static func backupStoreFiles(at storeURL: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return }
        let backupDir = appSupport.appendingPathComponent("StoreBackup-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeURL.path + suffix)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = backupDir.appendingPathComponent(storeURL.lastPathComponent + suffix + ".bak")
            try? FileManager.default.copyItem(at: src, to: dst)
        }
        NSLog("⚠️ Rhapsode: SwiftData store backed up to %@", backupDir.path)
    }

    /// Shared backend wiring for foreground `SyncManager` and `BackgroundRefresh`.
    @MainActor
    static func makeSyncManager(container: ModelContainer) -> SyncManager {
        // Backend preference is read at launch (change in Settings, then relaunch):
        // SMB NAS > rhapsode-server (parked) > Dropbox.
        let dropbox = DropboxSource()
        let dropboxConnected = ((try? KeychainTokenStore().load()) ?? nil) != nil
        let progress: ProgressSync = dropboxConnected
            ? DropboxProgressSync(source: dropbox)
            : NoopProgressSync()
        let progressDropbox: DropboxSource? = dropboxConnected ? dropbox : nil

        if SmbConfig.shouldUseSmb {
            return SyncManager(
                source: SmbLibrarySource(),
                context: container.mainContext,
                progress: progress,
                progressDropbox: progressDropbox)
        }
        if RhapsodeServerConfig.shouldUseServer {
            let client = RhapsodeServerClient()
            return SyncManager(
                source: RhapsodeServerSource(client: client),
                context: container.mainContext,
                progress: progress,
                progressDropbox: progressDropbox)
        }
        return SyncManager(
            source: dropbox,
            context: container.mainContext,
            progress: progress,
            progressDropbox: progressDropbox)
    }

    #if DEBUG
    /// DEBUG-only: seed a few audiobooks with listened/saved stats so the Nerd Stats receipt can be
    /// previewed with data (launch arg `-seedstats`). Only runs on a COMPLETELY EMPTY library so it
    /// can never overwrite a real install's lifetime stats (it writes fixed totals to UserDefaults).
    @MainActor
    static func seedStats(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Audiobook>())) ?? []
        guard existing.isEmpty else { return }
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

