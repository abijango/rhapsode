import SwiftUI
#if targetEnvironment(macCatalyst)
import UIKit
#endif

// MARK: - Layout enum

/// Describes which root container to use based on the horizontal size class.
/// Expressed as a first-class type so the selection is testable without
/// depending on the full SwiftUI environment.
enum RootLayoutMode: Equatable {
    case tabs   // compact (iPhone, slide-over)
    case split  // regular (iPad full-screen, Stage Manager)

    static func resolve(_ sizeClass: UserInterfaceSizeClass?) -> RootLayoutMode {
        sizeClass == .regular ? .split : .tabs
    }
}

enum RootPlayerIntent {
    case browsing
    case showing(Audiobook)

    var book: Audiobook? {
        switch self {
        case .browsing: nil
        case .showing(let book): book
        }
    }
}

enum RootPlayerSurface: Equatable {
    case none, cover, detail
}

enum CompactRootTab: Int, Hashable {
    case audiobooks = 0
    case ebooks = 1
}

enum RootPlayerPresentation {
    static func surface(intent: RootPlayerIntent, layout: RootLayoutMode) -> RootPlayerSurface {
        switch intent {
        case .browsing:
            return .none
        case .showing:
            switch layout {
            case .tabs: return .cover
            case .split: return .detail
            }
        }
    }

    static func showsMiniPlayer(hasPlayingBook: Bool, surface: RootPlayerSurface) -> Bool {
        hasPlayingBook && surface == .none
    }
}

// MARK: - Sidebar item

/// Sidebar destinations in the split-view layout.
private enum SidebarItem: Int, CaseIterable, Identifiable {
    case audiobooks = 0
    case ebooks     = 1
    case stats      = 2
    case settings   = 3

    var id: Int { rawValue }

    var label: some View {
        switch self {
        case .audiobooks: Label("Audiobooks", systemImage: "headphones")
        case .ebooks:     Label("E-books",    systemImage: "books.vertical")
        case .stats:      Label("Nerd Stats", systemImage: "chart.bar")
        case .settings:   Label("Settings",   systemImage: "gearshape")
        }
    }
}

// MARK: - RootTabView

/// Top-level shell: Audiobooks and E-books on phone; four sidebar items on iPad.
///
/// - **Compact** (iPhone, Slide Over): `TabView`. The rich player is a cover.
/// - **Regular** (iPad, Mac): `NavigationSplitView`. The rich player overlays
///   the audiobooks shelf so the sidebar and shelf state stay.
struct RootTabView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(AudiobookPlayer.self) private var audioPlayer
    @Environment(\.scenePhase)            private var scenePhase
    @Environment(\.horizontalSizeClass)   private var hSizeClass

    @State private var tabSelection: CompactRootTab = Self.initialTabSelection
    @State private var sidebarItem: SidebarItem? = .audiobooks
    @State private var settingsPresented = Self.initialSettingsPresented
    @State private var downloadsPresented = false
    @State private var playerIntent: RootPlayerIntent = .browsing
    @Namespace private var playerCoverNamespace

    private var layout: RootLayoutMode { RootLayoutMode.resolve(hSizeClass) }
    private var surface: RootPlayerSurface {
        RootPlayerPresentation.surface(intent: playerIntent, layout: layout)
    }
    private var showsMiniPlayer: Bool {
        RootPlayerPresentation.showsMiniPlayer(
            hasPlayingBook: audioPlayer.book != nil,
            surface: surface
        )
    }
    /// Cover binding is compact-only. Ignore a false write while the split
    /// branch is mounted so a size-class flip does not drop `.showing`.
    private var coverPresented: Binding<Bool> {
        Binding(
            get: { surface == .cover },
            set: { presented in
                if !presented, layout == .tabs {
                    tabSelection = .audiobooks
                    playerIntent = .browsing
                }
            }
        )
    }

    private static var initialTabSelection: CompactRootTab {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-tab"),
           i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] {
            case "ebooks": return .ebooks
            default:       return .audiobooks
            }
        }
        #endif
        return .audiobooks
    }

    private static var initialSettingsPresented: Bool {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-tab"),
           i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] {
            case "settings", "stats": return true
            default:                  return false
            }
        }
        #endif
        return false
    }

    var body: some View {
        Group {
            switch layout {
            case .tabs:  compactTabs
            case .split: regularSplit
            }
        }
        .focusedValue(\.audiobookPlayer, audioPlayer.book != nil ? audioPlayer : nil)
        .environment(\.expandAudiobookPlayer, expandPlayer(for:))
        .environment(\.openSettings, openSettings)
        .environment(\.openDownloads, openDownloads)
        .sheet(isPresented: $downloadsPresented) {
            NavigationStack {
                DownloadsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { downloadsPresented = false }
                        }
                    }
            }
        }
        // Foreground auto-detect: start the watcher + quiet catalogue refresh after
        // the shelf paints so Continue stays tappable. Stop watching when backgrounded.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                // The headless self-test drives its own SyncManagers over the shared context;
                // starting the live watcher/scan here would race its store mutations. Skip it.
                #if DEBUG
                let selfTest = PhaseZeroSelfTest.isRequested
                #else
                let selfTest = false
                #endif
                if !selfTest { Task { await sync.ensureWatching() } }
                #if targetEnvironment(macCatalyst)
                // Apply now, and once more after the scene settles — sizeRestrictions
                // is often unavailable at the first .active tick (the source of the
                // earlier "window won't resize"), so the delayed pass is load-bearing.
                Self.configureCatalystWindow()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    Self.configureCatalystWindow()
                }
                #endif
            } else {
                sync.stopWatching()
                if phase == .background {
                    BackgroundRefresh.schedule()
                    Task { await sync.pushSmartSpeechStats() }
                }
                if phase == .inactive || phase == .background {
                    // WP-B: persist live position before suspension (including force-quit via
                    // inactive). `savePosition()` triggers the wired onProgressChanged push.
                    audioPlayer.savePosition()
                }
            }
        }
    }

    private func expandPlayer(for book: Audiobook) {
        playerIntent = .showing(book)
        if layout == .split {
            sidebarItem = .audiobooks
        }
    }

    private func openSettings() {
        if layout == .tabs {
            settingsPresented = true
        } else {
            sidebarItem = .settings
        }
    }

    private func openDownloads() {
        downloadsPresented = true
    }

    #if targetEnvironment(macCatalyst)
    /// Make the Mac Catalyst window freely resizable. On Catalyst the window is a
    /// `UIWindowScene` whose `sizeRestrictions` govern resizing (SwiftUI's
    /// `.windowResizability` Scene modifier does not control it here); widen them to
    /// a sane minimum and a large maximum. Must run after the scene is active —
    /// `sizeRestrictions` can be nil earlier (see the delayed retry at the call site).
    static func configureCatalystWindow() {
        for ws in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            if let r = ws.sizeRestrictions {
                r.minimumSize = CGSize(width: 600, height: 480)
                r.maximumSize = CGSize(width: 10_000, height: 10_000)
            }
            ws.titlebar?.titleVisibility = .hidden
        }
    }
    #endif

    // MARK: Compact (iPhone)

    private var compactTabs: some View {
        accessoryAttachedTabs
            .sheet(isPresented: $settingsPresented) {
                SettingsView(showsCloseButton: true)
            }
            .fullScreenCover(isPresented: coverPresented) {
                if let book = playerIntent.book ?? audioPlayer.book {
                    ExpandedNowPlayingView(book: book, coverNamespace: playerCoverNamespace)
                }
            }
    }

    @ViewBuilder
    private var accessoryAttachedTabs: some View {
        if #available(iOS 26.1, *) {
            compactTabView.tabViewBottomAccessory(isEnabled: showsMiniPlayer) {
                miniPlayerAccessory
            }
        } else if showsMiniPlayer {
            compactTabView.tabViewBottomAccessory { miniPlayerAccessory }
        } else {
            compactTabView
        }
    }

    private var compactTabView: some View {
        TabView(selection: $tabSelection) {
            AudiobooksShelfView()
                .tabItem { Label("Audiobooks", systemImage: "headphones") }
                .badge(sync.newRemoteCount(kind: .audiobooks))
                .tag(CompactRootTab.audiobooks)

            BooksShelfView()
                .tabItem { Label("E-books", systemImage: "books.vertical") }
                .badge(sync.newRemoteCount(kind: .books))
                .tag(CompactRootTab.ebooks)
        }
    }

    // MARK: Regular (iPad)

    private func sidebarBadge(for item: SidebarItem) -> Int {
        switch item {
        case .audiobooks: sync.newRemoteCount(kind: .audiobooks)
        case .ebooks:     sync.newRemoteCount(kind: .books)
        default:          0
        }
    }

    private var regularSplit: some View {
        NavigationSplitView {
            // Use List(selection:) without NavigationLink wrappers: the List
            // drives sidebarItem directly and the detail column switches on it.
            // Mixing NavigationLink(value:) with a selection binding competes —
            // the link registers a navigation intent that may not update selection.
            List(SidebarItem.allCases, id: \.id, selection: $sidebarItem) { item in
                item.label
                    .badge(sidebarBadge(for: item))
                    .tag(item)
            }
            .navigationTitle("")
        } detail: {
            switch sidebarItem ?? .audiobooks {
            case .audiobooks:
                ZStack {
                    AudiobooksShelfView(showsShelfChrome: surface != .detail)
                        .opacity(surface == .detail ? 0 : 1)
                        .allowsHitTesting(surface != .detail)
                        .accessibilityHidden(surface == .detail)
                    if surface == .detail, let book = playerIntent.book {
                        SplitNowPlayingView(book: book, coverNamespace: playerCoverNamespace) {
                            playerIntent = .browsing
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            case .ebooks:     BooksShelfView()
            case .stats:      NerdStatsView()
            case .settings:   SettingsView()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            nowPlayingAccessory
        }
        .onChange(of: sidebarItem) { _, new in
            if new != .audiobooks, case .showing = playerIntent {
                playerIntent = .browsing
            }
        }
    }

    @ViewBuilder
    private var nowPlayingAccessory: some View {
        if showsMiniPlayer {
            miniPlayerAccessory
        }
    }

    private var miniPlayerAccessory: some View {
        NowPlayingAccessory(coverNamespace: playerCoverNamespace) {
            if let book = audioPlayer.book {
                expandPlayer(for: book)
            }
        }
    }
}
