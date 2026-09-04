import SmartSpeechKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Root (sparse index — matches iOS Settings hierarchy)

private struct SettingsIndexRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    var status: String? = nil
    var badge: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))

            Text(title)

            Spacer(minLength: 8)

            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DS.Palette.accent, in: Capsule())
            }

            if let status {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// App settings root. Keeps the top level scannable: one row per area with a
/// status subtitle; dense controls live one level down (HIG: hierarchical lists,
/// essential info first, secondary detail on drill-down).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SyncManager.self) private var sync
    @Query(sort: \DownloadItem.remoteEntryID) private var downloadItems: [DownloadItem]

    @AppStorage(AppAppearance.storageKey) private var appearanceRaw = AppAppearance.system.rawValue
    @State private var smartSpeechEnabled = SmartSpeechPreferences.isEnabled
    var showsCloseButton = false

    private let dropboxKeychain = KeychainTokenStore()

    var body: some View {
        NavigationStack {
            Form {
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
                        SettingsIndexRow(
                            title: "Library Sources",
                            systemImage: "externaldrive.connected.to.line.below",
                            tint: .blue,
                            status: librarySourceStatus
                        )
                    }

                    NavigationLink {
                        DownloadsView()
                    } label: {
                        SettingsIndexRow(
                            title: "Downloads",
                            systemImage: "arrow.down.circle",
                            tint: .teal,
                            badge: downloadAttentionBadge
                        )
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
                        SettingsIndexRow(
                            title: SmartSpeechBranding.featureName,
                            systemImage: "waveform",
                            tint: DS.Palette.Reclaim.mint,
                            status: smartSpeechEnabled ? "On" : "Off"
                        )
                    }

                    NavigationLink {
                        NerdStatsView(embedsNavigationStack: false)
                    } label: {
                        SettingsIndexRow(
                            title: "Nerd Stats",
                            systemImage: "chart.bar",
                            tint: .indigo
                        )
                    }
                } header: {
                    Text("Playback")
                }

                Section {
                    NavigationLink {
                        ProgressSyncSettingsView()
                    } label: {
                        SettingsIndexRow(
                            title: "Progress Sync",
                            systemImage: "arrow.triangle.2.circlepath.icloud",
                            tint: .purple,
                            status: progressSyncStatus
                        )
                    }
                    NavigationLink {
                        KOSyncSettingsView()
                    } label: {
                        SettingsIndexRow(
                            title: "KOReader Sync",
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: .orange,
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
            .toolbar {
                if showsCloseButton {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
            }
            .task { smartSpeechEnabled = SmartSpeechPreferences.isEnabled }
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

    private var downloadAttentionBadge: Int? {
        let count = DownloadQueueGrouper.attentionCount(from: downloadItems)
        return count > 0 ? count : nil
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
