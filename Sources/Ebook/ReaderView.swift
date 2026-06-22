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
    @State private var reader = EbookReader()
    @State private var showSettings = false
    @State private var showTOC = false

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
        .task { await reader.open(book, context: modelContext) }
        // Hardware-keyboard page-turn keys (iPad + Mac Catalyst).
        // These are additive — pressing keys is a no-op on iPhone where no keyboard
        // is attached. The shortcuts live on hidden buttons so they don't appear in
        // menus; right-arrow / left-arrow are the standard reader conventions.
        .background {
            Group {
                Button("") { reader.goForward()  }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { reader.goBackward() }.keyboardShortcut(.leftArrow,  modifiers: [])
            }
            .accessibilityHidden(true)
            .opacity(0)
        }
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
