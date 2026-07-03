import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftData
import SwiftUI

/// Reader-view appearance settings, mapped onto Readium's `EPUBPreferences`.
struct ReaderSettings: Equatable {
    enum ReaderTheme: String, CaseIterable, Identifiable {
        case light, dark, sepia
        var id: String { rawValue }
        var readium: ReadiumNavigator.Theme {
            switch self {
            case .light: .light
            case .dark: .dark
            case .sepia: .sepia
            }
        }
    }

    var fontSize: Double = 1.0   // 1.0 = 100%
    var theme: ReaderTheme = .light

    var epubPreferences: EPUBPreferences {
        EPUBPreferences(fontSize: fontSize, theme: theme.readium)
    }
}

/// Owns the Readium `Publication` + `EPUBNavigatorViewController`, applies
/// appearance preferences, persists the reading `Locator`, and exposes the TOC.
@MainActor
@Observable
final class EbookReader: NSObject {
    private(set) var navigator: EPUBNavigatorViewController?
    private(set) var toc: [ReadiumShared.Link] = []
    private(set) var loadError: String?

    /// Readium's helper that turns edge taps / mouse clicks and arrow/space keys
    /// into page turns. MUST be retained: its `deinit` unbinds the navigator
    /// observers, so a local would deallocate immediately and do nothing. It hooks
    /// the navigator/webview input layer, which is why it works on Mac Catalyst
    /// where SwiftUI keyboard shortcuts above the web view were swallowed.
    private var directionalAdapter: DirectionalNavigationAdapter?
    var settings = ReaderSettings() {
        didSet { if settings != oldValue { navigator?.submitPreferences(settings.epubPreferences) } }
    }

    private var book: Book?
    private var context: ModelContext?

    /// WP-C — set true while applying a remote (cross-device) reading position so `persist`
    /// updates the locator WITHOUT stamping `progressUpdatedAt` (the position carries the
    /// REMOTE timestamp; re-stamping it as a local change would bounce it back, anti-echo).
    private var applyingRemote = false

    /// WP-B — fired from the `locationDidChange` persist path when the locator genuinely moved
    /// and is user-driven (not a remote auto-jump), so the view can push the latest reading
    /// position cross-device on more than just navigate-away. `ReaderView` debounces it; the
    /// callback itself is unthrottled here. Set in `ReaderView`.
    var onProgressChanged: (() -> Void)?

    /// Open the book and build the navigator, restoring the saved locator.
    func open(_ book: Book, context: ModelContext) async {
        self.book = book
        self.context = context
        do {
            let url = try ContainerPaths.url(forRelativePath: book.fileRelPath)
            let publication = try await EbookImporter.openPublication(at: url)

            let initial = book.readingLocator.flatMap { Self.locator(fromJSON: $0) }
            var config = EPUBNavigatorViewController.Configuration()
            config.preferences = settings.epubPreferences

            let nav = try EPUBNavigatorViewController(
                publication: publication,
                initialLocation: initial,
                config: config
            )
            nav.delegate = self
            navigator = nav

            // Wire edge-tap / mouse-click + arrow/space-key page turns. Defaults
            // already handle touch + mouse on the horizontal edges and the arrow
            // and space keys, which covers iPhone, iPad, and Mac.
            let adapter = DirectionalNavigationAdapter(animatedTransition: true)
            adapter.bind(to: nav)
            directionalAdapter = adapter

            toc = (try? await publication.tableOfContents().get()) ?? []
        } catch {
            loadError = "Couldn’t open book: \(error.localizedDescription)"
        }
    }

    func go(to link: ReadiumShared.Link) {
        guard let navigator else { return }
        Task { await navigator.go(to: link) }
    }

    /// WP-C — auto-jump the open reader to a newer reading position merged from another
    /// device. Decodes the locator JSON (kept here so `SyncManager` needn't import Readium)
    /// and navigates. Sets `applyingRemote` so the resulting `locationDidChange` does NOT
    /// re-stamp/re-push (anti-echo, rule 3); the `changed` guard in `persist` is a second
    /// line of defence since the navigated locator serializes equal to the just-merged one.
    func applyRemoteLocator(json: String) {
        guard let navigator, let locator = Self.locator(fromJSON: json) else { return }
        applyingRemote = true
        Task {
            await navigator.go(to: locator)
            applyingRemote = false
        }
    }

    /// Advance one page. Called by keyboard shortcut (right/space on iPad keyboard).
    func goForward() {
        guard let navigator else { return }
        Task { await navigator.goForward() }
    }

    /// Go back one page. Called by keyboard shortcut (left arrow on iPad keyboard).
    func goBackward() {
        guard let navigator else { return }
        Task { await navigator.goBackward() }
    }

    // MARK: Locator persistence

    private func persist(_ locator: Locator) {
        guard let book, let context else { return }
        // WP-A: stamp progressUpdatedAt ONLY on a genuine page turn (the locator actually moved)
        // and only when not applying a remote auto-jump. The stored `readingLocator` IS the
        // change baseline, so the initial settle event (which re-delivers the restored position)
        // serializes equal and does not phantom-stamp.
        let newJSON = try? locator.jsonString()
        let changed = newJSON != nil && newJSON != book.readingLocator
        if changed && !applyingRemote {
            book.progressUpdatedAt = Date()
        }
        book.readingLocator = newJSON
        try? context.save()
        // WP-B: push the latest reading position cross-device. Fire AFTER the save (the push
        // re-fetches the row by key and reads its persisted locator) and only on a genuine,
        // user-driven move: the same `changed` gate suppresses the initial settle event (the
        // restored locator serializes equal) and `!applyingRemote` honours anti-echo (rule 3).
        if changed && !applyingRemote { onProgressChanged?() }
    }

    private static func locator(fromJSON json: String) -> Locator? {
        guard let value = try? JSONValue(jsonString: json, warnings: nil) else { return nil }
        return try? Locator(json: value, warnings: nil)
    }
}

extension EbookReader: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        persist(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        loadError = "Reader error: \(error)"
    }
}
