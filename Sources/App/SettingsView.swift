import SmartSpeechKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Root (sparse index — matches iOS Settings hierarchy)

/// App settings root. Keeps the top level scannable: one row per area with a
/// status subtitle; dense controls live one level down (HIG: hierarchical lists,
/// essential info first, secondary detail on drill-down).
struct SettingsView: View {
    @Environment(SyncManager.self) private var sync
    @Query(sort: \DownloadItem.remoteEntryID) private var downloadItems: [DownloadItem]

    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var smartSpeechEnabled = SmartSpeechPreferences.isEnabled

    private let dropboxKeychain = KeychainTokenStore()

    var body: some View {
        NavigationStack {
            Form {
                // Frequent, low-density controls stay on the root.
                Section {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                }

                Section {
                    NavigationLink {
                        LibrarySourceSettingsView()
                    } label: {
                        settingsRow(
                            title: "Library Sources",
                            systemImage: "externaldrive.connected.to.line.below",
                            status: librarySourceStatus
                        )
                    }

                    NavigationLink {
                        DownloadsView()
                    } label: {
                        HStack {
                            Label("Downloads", systemImage: "arrow.down.circle")
                            Spacer()
                            let count = DownloadQueueGrouper.attentionCount(from: downloadItems)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(DS.Palette.accent, in: Capsule())
                            }
                        }
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("Add SMB storage (VidHub-style), Dropbox, or a parked server. Manage downloads.")
                }

                Section {
                    NavigationLink {
                        SmartSpeechSettingsView()
                    } label: {
                        settingsRow(
                            title: SmartSpeechBranding.featureName,
                            systemImage: "waveform",
                            status: smartSpeechEnabled ? "On" : "Off"
                        )
                    }
                } header: {
                    Text("Playback")
                }

                Section {
                    NavigationLink {
                        ProgressSyncSettingsView()
                    } label: {
                        settingsRow(
                            title: "Progress Sync",
                            systemImage: "arrow.triangle.2.circlepath.icloud",
                            status: progressSyncStatus
                        )
                    }
                    NavigationLink {
                        KOSyncSettingsView()
                    } label: {
                        settingsRow(
                            title: "KOReader Sync",
                            systemImage: "arrow.triangle.2.circlepath",
                            status: KOSyncSettings.isConfigured ? "On" : "Off"
                        )
                    }
                } header: {
                    Text("Reading")
                } footer: {
                    Text("Audiobook resume and stats use Dropbox. Ebook position uses KOReader when it is on.")
                }
            }
            .navigationTitle("Settings")
            .task { smartSpeechEnabled = SmartSpeechPreferences.isEnabled }
            // Re-read when returning from a child so status labels stay fresh.
            .onAppear { smartSpeechEnabled = SmartSpeechPreferences.isEnabled }
        }
    }

    private var librarySourceStatus: String {
        if SmbConfig.shouldUseSmb { return "SMB NAS" }
        if RhapsodeServerConfig.shouldUseServer { return "Rhapsode Server" }
        if ((try? dropboxKeychain.load()) ?? nil) != nil { return "Dropbox" }
        if SmbConfig.isConfigured { return "SMB (off)" }
        if RhapsodeServerConfig.isConfigured { return "Server (off)" }
        return "Not set"
    }

    private var progressSyncStatus: String {
        if !sync.dropboxProgressConnected { return "Dropbox off" }
        if sync.progressPendingCount > 0 { return "\(sync.progressPendingCount) pending" }
        if sync.progressLastError != nil { return "Error" }
        return "Dropbox"
    }

    private func settingsRow(title: String, systemImage: String, status: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - SmartSpeech

struct SmartSpeechSettingsView: View {
    @State private var smartSpeechEnabled = SmartSpeechPreferences.isEnabled
    @State private var smartSpeechDefaultTier = SmartSpeechPreferences.defaultTier

    var body: some View {
        Form {
            Section {
                Toggle("Enable \(SmartSpeechBranding.featureName)", isOn: Binding(
                    get: { smartSpeechEnabled },
                    set: {
                        smartSpeechEnabled = $0
                        SmartSpeechPreferences.isEnabled = $0
                    }))
            } footer: {
                Text("Trims silence live during playback. Each audiobook can override this from its player.")
            }

            if smartSpeechEnabled {
                Section {
                    Picker("Default Sensitivity", selection: Binding(
                        get: { smartSpeechDefaultTier },
                        set: {
                            smartSpeechDefaultTier = $0
                            SmartSpeechPreferences.defaultTier = $0
                        })) {
                        ForEach(SmartSpeechSettings.Preset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Default profile")
                } footer: {
                    Text("Applies to books without their own setting. Fast narrators suit Default; slower narration may prefer More or Aggressive.")
                }
            }
        }
        .navigationTitle(SmartSpeechBranding.featureName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            smartSpeechEnabled = SmartSpeechPreferences.isEnabled
            smartSpeechDefaultTier = SmartSpeechPreferences.defaultTier
        }
    }
}
