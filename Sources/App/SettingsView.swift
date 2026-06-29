import CadenceKit
import SwiftData
import SwiftUI

/// Settings: Dropbox connection + the two watched-folder selections.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @State private var connection: ConnectionState = .unknown
    @State private var isConnecting = false
    @State private var errorMessage: String?

    // MARK: Cadence (global) — mirrors of the UserDefaults-backed prefs (not @Observable).
    @State private var cadenceEnabled = CadencePreferences.isEnabled
    @State private var cadenceDefaultTier = CadencePreferences.defaultTier
    @State private var cadenceTotalSaved: TimeInterval = 0
    @State private var cadenceBookCount = 0

    private let keychain = KeychainTokenStore()

    enum ConnectionState { case unknown, connected, disconnected }

    var body: some View {
        NavigationStack {
            Form {
                Section("Dropbox") {
                    if !DropboxConfig.isConfigured {
                        Label("App key not set in DropboxConfig", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    switch connection {
                    case .connected:
                        LabeledContent("Status", value: "Connected")
                        Button("Disconnect", role: .destructive) { disconnect() }
                    default:
                        LabeledContent("Status", value: "Not connected")
                        Button {
                            connect()
                        } label: {
                            if isConnecting { ProgressView() } else { Text("Connect Dropbox") }
                        }
                        .disabled(isConnecting || !DropboxConfig.isConfigured)
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Watched Folders") {
                    LabeledContent("Audiobooks", value: DropboxConfig.audiobooksPath)
                    LabeledContent("Books", value: DropboxConfig.booksPath)
                }

                // MARK: Cadence (global) — lifetime stat hero + master switch + default profile.
                Section {
                    CadenceTimeSavedCard(totalSeconds: cadenceTotalSaved, bookCount: cadenceBookCount)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Toggle("Enable \(CadenceBranding.featureName)", isOn: Binding(
                        get: { cadenceEnabled },
                        set: { cadenceEnabled = $0; CadencePreferences.isEnabled = $0 }))

                    if cadenceEnabled {
                        Picker("Default Sensitivity", selection: Binding(
                            get: { cadenceDefaultTier },
                            set: { cadenceDefaultTier = $0; CadencePreferences.defaultTier = $0 })) {
                            ForEach(CadenceSettings.Preset.allCases, id: \.self) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Applies to books without their own setting. Fast, natural narrators sound best on Default; slower, more deliberate narration tolerates More or Aggressive.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(CadenceBranding.featureName)
                } footer: {
                    Text("Each audiobook can override this from its player — pick a different profile, or turn \(CadenceBranding.featureName) off just for that book.")
                }

                Section {
                    NavigationLink {
                        DownloadsView()
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                }

                #if DEBUG
                Section("Developer") {
                    Button("Insert sample audiobook") { insertSample() }
                }
                #endif
            }
            .navigationTitle("Settings")
            .task { refreshConnection(); refreshCadence() }
        }
    }

    private func refreshConnection() {
        connection = ((try? keychain.load()) ?? nil) != nil ? .connected : .disconnected
    }

    private func refreshCadence() {
        cadenceEnabled = CadencePreferences.isEnabled
        cadenceDefaultTier = CadencePreferences.defaultTier
        cadenceTotalSaved = CadenceStats.totalSavedSeconds
        let books = (try? modelContext.fetch(FetchDescriptor<Audiobook>())) ?? []
        cadenceBookCount = Audiobook.countWithCadenceSavings(books)
    }

    @MainActor
    private func connect() {
        errorMessage = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                let tokens = try await DropboxOAuth().connect()
                try keychain.save(tokens)
                connection = .connected
                // First-connect: create the watched roots if missing + seed cursors,
                // and ask for notification permission (used for download alerts).
                try await sync.bootstrap()
                await sync.requestNotificationPermission()
                // Folders now exist — start the foreground watcher immediately
                // (scenePhase won't change, so onChange won't start it this session).
                sync.startWatching()
            } catch {
                errorMessage = "Connect failed: \(error.localizedDescription)"
            }
        }
    }

    private func disconnect() {
        try? keychain.clear()
        connection = .disconnected
    }

    #if DEBUG
    /// Phase 0 verification: proves the insert→save→fetch path works end to end.
    private func insertSample() {
        let store = LibraryStore(context: modelContext)
        let book = Audiobook(title: "Sample Audiobook", author: "Test", sourcePath: "sample")
        store.insert(book)
        try? store.save()
    }
    #endif
}
