import SwiftUI

/// Dropbox progress status, pending outbox, last error, and a manual push.
struct ProgressSyncSettingsView: View {
    @Environment(SyncManager.self) private var sync
    @State private var isPushing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Dropbox", value: sync.dropboxProgressConnected ? "Connected" : "Not connected")
                LabeledContent("Pending", value: "\(sync.progressPendingCount)")
                LabeledContent("Last success", value: successLabel)
                if let error = sync.progressLastError, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("Resume, Nerd Stats, and collections sync through Dropbox so phone and Mac stay aligned when the NAS is offline. Library files still come from your active source.")
            }

            Section {
                Button {
                    pushNow()
                } label: {
                    if isPushing {
                        ProgressView()
                    } else {
                        Text("Push now")
                    }
                }
                .disabled(isPushing || !sync.dropboxProgressConnected)
            }

            if !sync.dropboxProgressConnected {
                Section {
                    NavigationLink("Connect Dropbox") {
                        DropboxSourceEditView(onChanged: {})
                    }
                }
            }
        }
        .navigationTitle("Progress Sync")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sync.refreshProgressStatus() }
    }

    private var successLabel: String {
        guard let date = sync.progressLastSuccessAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func pushNow() {
        isPushing = true
        Task {
            defer { isPushing = false }
            await sync.flushProgressOutbox(force: true)
        }
    }
}
