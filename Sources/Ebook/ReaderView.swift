import SwiftData
import SwiftUI
import UIKit

/// EPUB reader hosted on **foliate-js** (single WKWebView).
///
/// Immersive iPhone UX (Apple Books–style):
/// - Tab bar + nav chrome hidden while reading
/// - Center tap toggles chrome (title, TOC, fonts)
/// - Edge taps turn pages (inset so system edge-swipe can pop back to the shelf)
/// - Safe margins so text doesn’t kiss the screen edges
struct ReaderView: View {
    let book: Book
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(SyncManager.self) private var sync
    @State private var reader = FoliateWebReader()
    @State private var showSettings = false
    @State private var showTOC = false
    @State private var pushDebounce = PushDebounce()
    @State private var kosyncDebounce = PushDebounce()
    @State private var kosyncConflict: KOSyncConflict?
    /// Top chrome (nav bar + tools). Hidden for immersion; center-tap reveals.
    @State private var chromeVisible = false
    @State private var chromeHideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let error = reader.loadError, !reader.isOpen {
                ContentUnavailableView(
                    "Couldn’t Open Book",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else {
                ZStack {
                    // Stay below Dynamic Island / status bar; bottom can sit above home indicator.
                    // Tab bar is hidden separately. Do NOT ignore top safe area (text was clipped).
                    FoliateWebViewHost(reader: reader)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(edges: .bottom)

                    if !reader.isOpen {
                        ProgressView(reader.openingStatus ?? "Opening…")
                    }

                    if reader.isOpen, let error = reader.loadError {
                        VStack {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.red.opacity(0.85), in: Capsule())
                                .padding(.top, 8)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        // Full-screen reading: hide bottom tabs (same pattern as PlayerView).
        .toolbar(.hidden, for: .tabBar)
        .toolbar(chromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Contents", systemImage: "list.bullet") {
                    showTOC = true
                    scheduleChromeAutoHide()
                }
                .disabled(!reader.isOpen)

                Button("Reading settings", systemImage: "textformat.size") {
                    showSettings = true
                    scheduleChromeAutoHide()
                }
                .disabled(!reader.isOpen)
            }
        }
        .statusBarHidden(!chromeVisible && reader.isOpen)
        .animation(.easeInOut(duration: 0.2), value: chromeVisible)
        .task {
            reader.prepareWebViewIfNeeded()
            reader.onChromeToggle = { toggleChrome() }
            // Merge remote position before paint. Network already has a 20s timeout.
            let pull = await KOSyncService.pullAndApply(
                book: book, reader: nil, context: modelContext
            )
            if case .conflict(let localF, let remote) = pull {
                kosyncConflict = KOSyncConflict(localFraction: localF, remote: remote)
            }
            await reader.open(book, context: modelContext)
            reader.startReadingSession()
            sync.activeReader = reader
            sync.activeReaderBookID = book.id
            let key = book.fileRelPath
            reader.onProgressChanged = {
                pushDebounce.task?.cancel()
                pushDebounce.task = Task {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    await sync.pushBookProgress(relPath: key)
                }
                kosyncDebounce.task?.cancel()
                kosyncDebounce.task = Task {
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    await KOSyncService.push(book: book, context: modelContext)
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
                Task { await sync.pullAndMergeProgress() }
            case .inactive, .background:
                reader.flushPendingSave()
                reader.endReadingSession()
                let key = book.fileRelPath
                Task {
                    await sync.pushBookProgress(relPath: key)
                    await KOSyncService.push(book: book, context: modelContext)
                }
            @unknown default:
                break
            }
        }
        .onDisappear {
            chromeHideTask?.cancel()
            reader.cancelOpen()
            pushDebounce.task?.cancel()
            kosyncDebounce.task?.cancel()
            reader.flushPendingSave()
            reader.endReadingSession()
            let key = book.fileRelPath
            Task {
                await sync.pushBookProgress(relPath: key)
                await KOSyncService.push(book: book, context: modelContext)
            }
            if sync.activeReaderBookID == book.id {
                sync.activeReader = nil
                sync.activeReaderBookID = nil
            }
            reader.destroy()
        }
        .alert("Reading Position Conflict", isPresented: Binding(
            get: { kosyncConflict != nil },
            set: { if !$0 { kosyncConflict = nil } }
        )) {
            Button("Keep this device") {
                kosyncConflict = nil
                Task { await KOSyncService.push(book: book, context: modelContext) }
            }
            Button("Use other device") {
                if let remote = kosyncConflict?.remote {
                    KOSyncService.apply(
                        remote: remote, to: book, reader: reader, context: modelContext
                    )
                }
                kosyncConflict = nil
            }
        } message: {
            if let c = kosyncConflict {
                let localPct = Int((c.localFraction * 100).rounded())
                let remotePct = Int(((c.remote.fraction ?? 0) * 100).rounded())
                Text("This device is at \(localPct)%; another device is at \(remotePct)%. Which position do you want?")
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: { scheduleChromeAutoHide() }) {
            ReaderSettingsSheet(settings: $reader.settings)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTOC, onDismiss: { scheduleChromeAutoHide() }) {
            FoliateTOCSheet(toc: reader.toc) { item in
                reader.go(to: item)
                showTOC = false
            }
        }
    }

    // MARK: - Chrome

    private func toggleChrome() {
        if chromeVisible {
            hideChrome()
        } else {
            showChrome()
        }
    }

    private func showChrome() {
        chromeVisible = true
        scheduleChromeAutoHide()
    }

    private func hideChrome() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        chromeVisible = false
    }

    private func scheduleChromeAutoHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            // Keep chrome if a sheet is open.
            guard !showSettings, !showTOC else { return }
            chromeVisible = false
        }
    }
}

@MainActor private final class PushDebounce {
    var task: Task<Void, Never>?
}

private struct KOSyncConflict {
    var localFraction: Double
    var remote: KOSyncProgress
}

// MARK: - WKWebView host + keyboard

private struct FoliateWebViewHost: UIViewRepresentable {
    let reader: FoliateWebReader

    func makeUIView(context: Context) -> FoliateContainerView {
        let container = FoliateContainerView()
        container.reader = reader
        reader.prepareWebViewIfNeeded()
        container.attachWebViewIfNeeded()
        return container
    }

    func updateUIView(_ uiView: FoliateContainerView, context: Context) {
        uiView.reader = reader
        uiView.attachWebViewIfNeeded()
    }
}

/// Hosts the WKWebView and owns arrow/space page-turn key commands.
final class FoliateContainerView: UIView {
    var reader: FoliateWebReader?
    private weak var hostedWebView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attachWebViewIfNeeded() {
        guard let wv = reader?.webView else { return }
        if hostedWebView === wv { return }
        hostedWebView?.removeFromSuperview()
        wv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hostedWebView = wv
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            key(UIKeyCommand.inputRightArrow, #selector(fwd), "Next page"),
            key(UIKeyCommand.inputLeftArrow, #selector(back), "Previous page"),
            key(UIKeyCommand.inputDownArrow, #selector(fwd), "Next page"),
            key(UIKeyCommand.inputUpArrow, #selector(back), "Previous page"),
            key(" ", #selector(fwd), "Next page"),
        ]
    }

    private func key(_ input: String, _ sel: Selector, _ title: String) -> UIKeyCommand {
        let c = UIKeyCommand(input: input, modifierFlags: [], action: sel)
        c.wantsPriorityOverSystemBehavior = true
        c.discoverabilityTitle = title
        return c
    }

    @objc private func fwd() {
        _ = becomeFirstResponder()
        // Keyboard page-turns mirror edge taps (chrome stays hidden).
        reader?.goForward()
    }

    @objc private func back() {
        _ = becomeFirstResponder()
        reader?.goBackward()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            _ = becomeFirstResponder()
        }
    }
}

// MARK: - Sheets

private struct ReaderSettingsSheet: View {
    @Binding var settings: ReaderSettings
    @Environment(\.dismiss) private var dismiss

    @State private var customFonts: [CustomReaderFont] = CustomReaderFontStore.all()
    @State private var showImporter = false
    @State private var importError: String?

    private static let sampleParagraph =
        "It was the best of times, it was the worst of times — the age of wisdom and the age of foolishness."

    private var selectablePresets: [ReaderFontPreset] {
        ReaderFontCatalog.presets + customFonts.map { $0.asPreset() }
    }

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
                        ForEach(selectablePresets) { preset in
                            Text(preset.label).tag(ReaderFontChoice(rawValue: preset.id))
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
                Section {
                    ForEach(customFonts) { font in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(font.displayName)
                                Text(font.familyName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if settings.fontChoice.rawValue == font.preferenceID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityLabel("Selected")
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            settings.fontChoice = ReaderFontChoice(rawValue: font.preferenceID)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Delete", role: .destructive) {
                                deleteCustom(font)
                            }
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Add Font…", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Custom Fonts")
                } footer: {
                    Text("Import .ttf or .otf files stored on this device. Fonts stay offline in Application Support.")
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
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: CustomReaderFontStore.contentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("Couldn’t Import Font", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("OK", role: .cancel) { importError = nil }
            } message: {
                Text(importError ?? "")
            }
            .onAppear { refreshCustomFonts() }
        }
    }

    private func refreshCustomFonts() {
        customFonts = CustomReaderFontStore.all()
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let font = try CustomReaderFontStore.importFont(from: url)
                refreshCustomFonts()
                settings.fontChoice = ReaderFontChoice(rawValue: font.preferenceID)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func deleteCustom(_ font: CustomReaderFont) {
        let wasSelected = CustomReaderFontStore.delete(font)
        refreshCustomFonts()
        if wasSelected {
            settings.fontChoice = ReaderFontChoice(rawValue: ReaderFontCatalog.defaultID)
        }
    }
}

private struct FoliateTOCSheet: View {
    let toc: [FoliateTOCItem]
    let onSelect: (FoliateTOCItem) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if toc.isEmpty {
                    ContentUnavailableView("No Contents", systemImage: "list.bullet")
                } else {
                    List(toc) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            Text(item.label)
                                .foregroundStyle(.primary)
                                .padding(.leading, CGFloat(item.depth) * 12)
                        }
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
