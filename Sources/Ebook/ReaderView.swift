import ReadiumNavigator
import ReadiumShared
import SwiftData
import SwiftUI
import UIKit

/// EPUB reader screen. Hosts Readium's UIKit navigator, with a settings sheet
/// (font size / theme) and a TOC sheet. Resume is handled by `EbookReader`.
struct ReaderView: View {
    let book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @State private var reader = EbookReader()
    @State private var showSettings = false
    @State private var showTOC = false
    /// WP-B — holds the in-flight debounce task for the cross-device progress push. A reference
    /// type (not a `@State` value) so the escaping `onProgressChanged` closure mutates it through
    /// a stable identity; replacing a `@State` struct field from such a closure is unreliable.
    @State private var pushDebounce = PushDebounce()

    var body: some View {
        Group {
            if let navigator = reader.navigator {
                NavigatorHost(navigator: navigator)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = reader.loadError {
                ContentUnavailableView("Couldn’t Open Book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView("Opening…")
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showTOC = true } label: { Image(systemName: "list.bullet") }
                    .disabled(reader.navigator == nil)
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                    .disabled(reader.navigator == nil)
            }
        }
        .task {
            await reader.open(book, context: modelContext)
            // WP-C: register this open reader so a newer remote locator (pulled while the
            // reader is on screen) auto-jumps the page. Cleared in onDisappear.
            sync.activeReader = reader
            sync.activeReaderBookID = book.id
            // WP-B: continuous push on page turns, debounced ~6s so flicking through pages
            // coalesces into one upload. Capture the key (String) before the actor hop — the
            // Book model is not Sendable. The onDisappear push below covers the trailing edge.
            let key = book.fileRelPath
            reader.onProgressChanged = {
                pushDebounce.task?.cancel()
                pushDebounce.task = Task {
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    await sync.pushBookProgress(relPath: key)
                }
            }
        }
        .onDisappear {
            // WP-C: deregister this reader so remote merges no longer try to drive a gone view.
            if sync.activeReaderBookID == book.id {
                sync.activeReader = nil
                sync.activeReaderBookID = nil
            }
            // The reader persists the locator locally on every page turn; push the
            // latest for cross-device resume. Capture the key (String) before the
            // actor hop — the Book model is not Sendable.
            // WP-B: cancel any pending debounced push — this onDisappear push is the
            // trailing edge and supersedes it (avoids a duplicate upload moments later).
            pushDebounce.task?.cancel()
            let key = book.fileRelPath
            Task { await sync.pushBookProgress(relPath: key) }
        }
        // Page turns (edge tap / mouse click + arrow/space keys) are handled by
        // Readium's DirectionalNavigationAdapter, bound in EbookReader.open — it
        // hooks the navigator's input layer, so it works on Mac Catalyst where
        // SwiftUI keyboard shortcuts above the web view were swallowed.
        .sheet(isPresented: $showSettings) {
            ReaderSettingsSheet(settings: $reader.settings)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTOC) {
            TOCSheet(toc: reader.toc) { link in
                reader.go(to: link)
                showTOC = false
            }
        }
    }
}

/// WP-B — stable reference holder for the debounced cross-device push task. Held as `@State`
/// in `ReaderView` so the escaping `onProgressChanged` closure can cancel/replace the in-flight
/// task through a fixed identity (mutating a `@State` struct field from such a closure is
/// unreliable). Main-actor-isolated to match `ReaderView`'s body.
@MainActor private final class PushDebounce {
    var task: Task<Void, Never>?
}

/// Bridges the UIKit `EPUBNavigatorViewController` into SwiftUI.
private struct NavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    func makeUIViewController(context: Context) -> EPUBNavigatorViewController { navigator }
    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}

private struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(ReaderSettings.ReaderTheme.allCases) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Font Size") {
                    Slider(value: $settings.fontSize, in: 0.5...2.0, step: 0.1) { Text("Font Size") }
                    Text("\(Int(settings.fontSize * 100))%").font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct TOCSheet: View {
    let toc: [ReadiumShared.Link]
    let onSelect: (ReadiumShared.Link) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if toc.isEmpty {
                    ContentUnavailableView("No Contents", systemImage: "list.bullet")
                } else {
                    List(toc, id: \.href) { link in
                        Button(link.title ?? link.href) { onSelect(link) }
                            .tint(.primary)
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
