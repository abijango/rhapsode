import SwiftUI

/// Top-level shell: Audiobooks / E-books / Settings.
struct RootTabView: View {
    @Environment(SyncManager.self) private var sync
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = Self.initialSelection

    private static var initialSelection: Int {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-tab"),
           i + 1 < CommandLine.arguments.count {
            switch CommandLine.arguments[i + 1] {
            case "ebooks": return 1
            case "settings": return 2
            default: return 0
            }
        }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $selection) {
            AudiobooksShelfView()
                .tabItem {
                    Label("Audiobooks", systemImage: "headphones")
                }
                .tag(0)

            BooksShelfView()
                .tabItem {
                    Label("E-books", systemImage: "books.vertical")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(2)
        }
        // Foreground auto-detect: watch Dropbox while active, stop when backgrounded.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await sync.ensureWatching() }
            } else {
                sync.stopWatching()
                if phase == .background { BackgroundRefresh.schedule() }
            }
        }
    }
}

