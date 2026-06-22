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

// MARK: - Sidebar item

/// Sidebar destinations in the split-view layout.
private enum SidebarItem: Int, CaseIterable, Identifiable {
    case audiobooks = 0
    case ebooks     = 1
    case settings   = 2

    var id: Int { rawValue }

    var label: some View {
        switch self {
        case .audiobooks: Label("Audiobooks", systemImage: "headphones")
        case .ebooks:     Label("E-books",    systemImage: "books.vertical")
        case .settings:   Label("Settings",   systemImage: "gearshape")
        }
    }
}

// MARK: - RootTabView

/// Top-level shell: Audiobooks / E-books / Settings.
///
/// - **Compact** (iPhone, Slide Over): `TabView` — preserves the original UX.
/// - **Regular** (iPad): `NavigationSplitView` with a sidebar of sections and a
///   detail column that hosts the selected shelf or settings screen.
struct RootTabView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(\.scenePhase)            private var scenePhase
    @Environment(\.horizontalSizeClass)   private var hSizeClass

    // Compact path — tab index
    @State private var tabSelection  = Self.initialTabSelection
    // Regular path — sidebar selection
    @State private var sidebarItem: SidebarItem? = .audiobooks

    private static var initialTabSelection: Int {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-tab"),
           i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] {
            case "ebooks":   return 1
            case "settings": return 2
            default:         return 0
            }
        }
        #endif
        return 0
    }

    var body: some View {
        Group {
            switch RootLayoutMode.resolve(hSizeClass) {
            case .tabs:  compactTabs
            case .split: regularSplit
            }
        }
        // Foreground auto-detect: watch Dropbox while active, stop when backgrounded.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await sync.ensureWatching() }
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
                if phase == .background { BackgroundRefresh.schedule() }
            }
        }
    }

    #if targetEnvironment(macCatalyst)
    /// Make the Mac Catalyst window freely resizable. On Catalyst the window is a
    /// `UIWindowScene` whose `sizeRestrictions` govern resizing (SwiftUI's
    /// `.windowResizability` Scene modifier does not control it here); widen them to
    /// a sane minimum and a large maximum. Must run after the scene is active —
    /// `sizeRestrictions` can be nil earlier (see the delayed retry at the call site).
    static func configureCatalystWindow() {
        for ws in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            guard let r = ws.sizeRestrictions else { continue }
            r.minimumSize = CGSize(width: 600, height: 480)
            r.maximumSize = CGSize(width: 10_000, height: 10_000)
        }
    }
    #endif

    // MARK: Compact (iPhone)

    private var compactTabs: some View {
        TabView(selection: $tabSelection) {
            AudiobooksShelfView()
                .tabItem { Label("Audiobooks", systemImage: "headphones") }
                .tag(0)

            BooksShelfView()
                .tabItem { Label("E-books", systemImage: "books.vertical") }
                .tag(1)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
    }

    // MARK: Regular (iPad)

    private var regularSplit: some View {
        NavigationSplitView {
            // Use List(selection:) without NavigationLink wrappers: the List
            // drives sidebarItem directly and the detail column switches on it.
            // Mixing NavigationLink(value:) with a selection binding competes —
            // the link registers a navigation intent that may not update selection.
            List(SidebarItem.allCases, id: \.id, selection: $sidebarItem) { item in
                item.label.tag(item)
            }
            .navigationTitle("Rhapsode")
        } detail: {
            switch sidebarItem ?? .audiobooks {
            case .audiobooks: AudiobooksShelfView()
            case .ebooks:     BooksShelfView()
            case .settings:   SettingsView()
            }
        }
    }
}
