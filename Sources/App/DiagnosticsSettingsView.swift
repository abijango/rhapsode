import SwiftUI

/// On-device log viewer. Share the file after a crash — nothing leaves the phone until you do.
///
/// The log rolls at midnight and yesterday's lines move into a zipped day archive, so "Share
/// today's log" is always a short, fresh file rather than a fortnight of history. **Start fresh**
/// is the button to press before reproducing a bug you want to report.
struct DiagnosticsSettingsView: View {
    @State private var logText = ""
    @State private var byteCount = 0
    @State private var exportURL: URL?
    @State private var bundleURL: URL?
    @State private var archives: [(name: String, bytes: Int)] = []
    @State private var confirmClear = false
    @State private var confirmClearArchives = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Today", value: sizeLabel(byteCount))
                LabeledContent("Archived days", value: "\(archives.count)")
                LabeledContent("Crash leftover", value: DiagnosticLog.hasPendingCrash ? "Yes — see log" : "None")
            } footer: {
                Text("Logs roll over at midnight; older days are zipped and kept for two weeks. "
                     + "Lines may include book titles and file names. Tokens are never written.")
            }

            Section {
                Button {
                    DiagnosticLog.clear()
                    refresh()
                } label: {
                    Label("Start fresh", systemImage: "sparkles")
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share today's log", systemImage: "square.and.arrow.up")
                    }
                }
                if let bundleURL {
                    ShareLink(item: bundleURL) {
                        Label("Share all logs (.zip)", systemImage: "doc.zipper")
                    }
                }
                Button("Refresh") { refresh() }
            } header: {
                Text("Report a bug")
            } footer: {
                Text("Tap Start fresh, reproduce the problem, then share today's log. "
                     + "That gives a short log with only the relevant run in it.")
            }

            if !archives.isEmpty {
                Section {
                    ForEach(archives, id: \.name) { archive in
                        LabeledContent(archive.name.replacingOccurrences(of: "rhapsode-", with: "")
                                                   .replacingOccurrences(of: ".log.zip", with: ""),
                                       value: sizeLabel(archive.bytes))
                            .font(.subheadline)
                    }
                    Button("Delete archives", role: .destructive) { confirmClearArchives = true }
                } header: {
                    Text("Archived days")
                }
            }

            Section {
                ScrollView {
                    Text(logText.isEmpty ? "No log yet. Use the app, then refresh." : logText)
                        .font(ReceiptFont.mono(10))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 360)
            } header: {
                Text("Recent lines")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            DiagnosticLog.clearPendingCrashFlag()
            refresh()
        }
        .confirmationDialog("Clear today's log?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear log", role: .destructive) {
                DiagnosticLog.clear()
                refresh()
            }
        }
        .confirmationDialog("Delete every archived day?", isPresented: $confirmClearArchives,
                            titleVisibility: .visible) {
            Button("Delete archives", role: .destructive) {
                DiagnosticLog.clearArchives()
                refresh()
            }
        }
    }

    private func sizeLabel(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private func refresh() {
        logText = DiagnosticLog.readRecent()
        byteCount = DiagnosticLog.byteCount()
        archives = DiagnosticLog.archives()
        exportURL = DiagnosticLog.exportFile()
        // Zipping the whole folder is the one genuinely slow step here, so it lands after the
        // screen has drawn rather than holding it up. The button simply appears when ready.
        bundleURL = nil
        Task.detached(priority: .utility) {
            let url = DiagnosticLog.exportArchiveBundle()
            await MainActor.run { bundleURL = url }
        }
    }
}
