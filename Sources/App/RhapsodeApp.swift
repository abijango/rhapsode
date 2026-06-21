import SwiftData
import SwiftUI

@main
struct RhapsodeApp: App {
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
        _sync = State(initialValue: SyncManager(source: DropboxSource(), context: container.mainContext))
        // Register the background-refresh handler before launch completes.
        BackgroundRefresh.register(container: container)
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
    }
}
