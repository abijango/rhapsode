import ReadiumNavigator
import ReadiumShared
import SwiftData
import SwiftUI
import UIKit

/// EPUB reader screen.
///
/// Page turns follow the Readium TestApp model:
/// - **Edge click / tap** and **arrow / space keys** → `DirectionalNavigationAdapter`
/// - **Toolbar chevrons** → `EbookReader.goForward/goBackward`
///
/// Do not stack SwiftUI edge overlays on top of the adapter — that double-fires
/// turns and leaves the navigator stuck.
struct ReaderView: View {
    let book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncManager.self) private var sync
    @State private var reader = EbookReader()
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var pushDebounce = PushDebounce()

    var body: some View {
        Group {
            if let navigator = reader.navigator {
                NavigatorHost(navigator: navigator)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .bottom)
            } else if let error = reader.loadError {
                ContentUnavailableView(
                    "Couldn’t Open Book",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ProgressView("Opening…")
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button {
                    EbookReader.log("toolbar ←")
                    reader.goBackward()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(reader.navigator == nil)
                .accessibilityLabel("Previous page")

                Button {
                    EbookReader.log("toolbar →")
                    reader.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(reader.navigator == nil)
                .accessibilityLabel("Next page")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showTOC = true } label: { Image(systemName: "list.bullet") }
                    .disabled(reader.navigator == nil)
                Button { showSettings = true } label: { Image(systemName: "textformat.size") }
                    .disabled(reader.navigator == nil)
            }
        }
        .task {
            await reader.open(book, context: modelContext)
            reader.startReadingSession()
            sync.activeReader = reader
            sync.activeReaderBookID = book.id
            let key = book.fileRelPath
            reader.onProgressChanged = {
                pushDebounce.task?.cancel()
                pushDebounce.task = Task {
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    await sync.pushBookProgress(relPath: key)
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { break }
                reader.flushReadingSession()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                reader.startReadingSession()
            case .inactive, .background:
                reader.endReadingSession()
                let key = book.fileRelPath
                Task { await sync.pushBookProgress(relPath: key) }
            @unknown default:
                break
            }
        }
        .onDisappear {
            if sync.activeReaderBookID == book.id {
                sync.activeReader = nil
                sync.activeReaderBookID = nil
            }
            pushDebounce.task?.cancel()
            reader.endReadingSession()
            let key = book.fileRelPath
            Task { await sync.pushBookProgress(relPath: key) }
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

@MainActor private final class PushDebounce {
    var task: Task<Void, Never>?
}

// MARK: - Host

/// Embeds Readium as a **child** VC so it gets a non-zero frame (required for
/// CSS column pagination). Does **not** steal first responder from the navigator
/// — keyboard page turns need the navigator as first responder.
private struct NavigatorHost: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> NavigatorContainerController {
        NavigatorContainerController(navigator: navigator)
    }

    func updateUIViewController(_ uiViewController: NavigatorContainerController, context: Context) {
        uiViewController.ensureEmbedded(navigator)
    }
}

final class NavigatorContainerController: UIViewController {
    private var navigator: EPUBNavigatorViewController?

    init(navigator: EPUBNavigatorViewController) {
        self.navigator = navigator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        if let navigator { embed(navigator) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Let the navigator take first responder (InputObservableViewController does
        // this too). Do NOT becomeFirstResponder() here — that steals keys from Readium.
        navigator?.view.endEditing(true)
        _ = navigator?.becomeFirstResponder()
        EbookReader.log("container appear bounds=\(view.bounds) navBounds=\(navigator?.view.bounds ?? .zero)")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        navigator?.view.frame = view.bounds
    }

    func ensureEmbedded(_ nav: EPUBNavigatorViewController) {
        guard navigator !== nav else {
            navigator?.view.frame = view.bounds
            return
        }
        if let old = navigator {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        navigator = nav
        if isViewLoaded { embed(nav) }
    }

    private func embed(_ nav: EPUBNavigatorViewController) {
        addChild(nav)
        nav.view.frame = view.bounds
        nav.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(nav.view)
        nav.didMove(toParent: self)
    }
}

// MARK: - Sheets

private struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    private static let sampleParagraph =
        "It was the best of times, it was the worst of times — the age of wisdom and the age of foolishness."

    var body: some View {
        NavigationStack {
            Form {
                Section("Theme") {
                    Picker("Theme", selection: $settings.theme) {
                        ForEach(ReaderSettings.ReaderTheme.allCases) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Picker("Typeface", selection: $settings.fontChoice) {
                        ForEach(ReaderFontChoice.allCases) { choice in
                            Text(choice.label).tag(choice)
                        }
                    }
                    Text(settings.fontChoice.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Self.sampleParagraph)
                        .font(.body)
                        .lineSpacing(4)
                        .padding(.vertical, DS.Spacing.xs)
                } header: {
                    Text("Typeface")
                } footer: {
                    Text("Changes apply immediately. Your choice is remembered for every book.")
                }
                Section("Font Size") {
                    Slider(value: $settings.fontSize, in: 0.5...2.0, step: 0.1) {
                        Text("Font Size")
                    }
                    Text("\(Int(settings.fontSize * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
