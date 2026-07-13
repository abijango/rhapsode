import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import SwiftData
import SwiftUI
import UIKit
import WebKit

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

    var fontChoice: ReaderFontChoice = .literata
    var fontSize: Double = 1.0   // 1.0 = 100%
    var theme: ReaderTheme = .light

    static func fromPreferences() -> ReaderSettings {
        ReaderSettings(
            fontChoice: ReaderPreferences.fontChoice,
            fontSize: ReaderPreferences.fontSize,
            theme: ReaderPreferences.theme
        )
    }

    func saveToPreferences() {
        ReaderPreferences.fontChoice = fontChoice
        ReaderPreferences.fontSize = fontSize
        ReaderPreferences.theme = theme
    }

    var epubPreferences: EPUBPreferences {
        // Paginated reflowable needs advanced Readium CSS (columns):
        // publisherStyles false + scroll false.
        if fontChoice == .publisher {
            return EPUBPreferences(
                fontSize: fontSize,
                publisherStyles: false,
                scroll: false,
                theme: theme.readium
            )
        }
        return EPUBPreferences(
            fontFamily: fontChoice.readiumFontFamily,
            fontSize: fontSize,
            publisherStyles: false,
            scroll: false,
            theme: theme.readium
        )
    }
}

/// Owns the Readium `Publication` + `EPUBNavigatorViewController`.
///
/// Page turns use Readium's `DirectionalNavigationAdapter` for edge click/tap and
/// arrow/space keys, plus toolbar chevrons via `goForward`/`goBackward`.
///
/// **Critical WebKit quirk:** with `animated: false`, Readium calls
/// `window.scrollBy({ behavior: 'instant' })`, which many WKWebView builds ignore
/// while still returning success — so the toolbar reports `ok=true` but the page
/// never moves. We always use **animated** turns, and if progression does not
/// change we fall back to UIKit `contentOffset` on the web scroll view.
@MainActor
@Observable
final class EbookReader: NSObject {
    private(set) var navigator: EPUBNavigatorViewController?
    private(set) var toc: [ReadiumShared.Link] = []
    private(set) var loadError: String?

    /// MUST be retained — `deinit` unbinds the navigator observers.
    private var directionalAdapter: DirectionalNavigationAdapter?

    var settings = ReaderSettings.fromPreferences() {
        didSet {
            guard settings != oldValue else { return }
            settings.saveToPreferences()
            navigator?.submitPreferences(settings.epubPreferences)
        }
    }

    private var book: Book?
    private var context: ModelContext?
    private var sessionStart: Date?
    private var applyingRemote = false
    private var turnInFlight = false

    var onProgressChanged: (() -> Void)?

    // MARK: - Open

    func open(_ book: Book, context: ModelContext) async {
        self.book = book
        self.context = context
        turnInFlight = false
        do {
            let url = try ContainerPaths.url(forRelativePath: book.fileRelPath)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                loadError = "Book file is empty or missing. Delete it and download again."
                return
            }
            if let fh = try? FileHandle(forReadingFrom: url) {
                let magic = try? fh.read(upToCount: 4)
                try? fh.close()
                if magic != Data([0x50, 0x4B, 0x03, 0x04]) && magic != Data([0x50, 0x4B, 0x05, 0x06]) {
                    loadError = "Book file is not a valid EPUB (corrupt download). Delete and download again."
                    return
                }
            }

            let publication = try await EbookImporter.openPublication(at: url)
            guard !publication.readingOrder.isEmpty else {
                loadError = "This EPUB has no readable chapters."
                return
            }
            Self.log(
                "open “\(book.title)” readingOrder=\(publication.readingOrder.count) size=\(size)"
            )

            let initial = book.readingLocator.flatMap { Self.locator(fromJSON: $0) }
            var config = EPUBNavigatorViewController.Configuration()
            var prefs = settings.epubPreferences
            prefs.scroll = false
            config.preferences = prefs
            config.defaults.scroll = false
            config.defaults.publisherStyles = false
            config.fontFamilyDeclarations = ReaderFonts.fontFamilyDeclarations()
            #if DEBUG
            config.debugState = true
            #endif

            let nav: EPUBNavigatorViewController
            do {
                nav = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: initial,
                    config: config
                )
            } catch {
                Self.log("open with locator failed (\(error)); retrying without restore")
                nav = try EPUBNavigatorViewController(
                    publication: publication,
                    initialLocation: nil,
                    config: config
                )
            }
            nav.delegate = self
            navigator = nav

            // Edge click/tap + keyboard. animatedTransition true → Readium uses
            // scrollBy(behavior:'smooth') which actually works in WKWebView.
            let adapter = DirectionalNavigationAdapter(
                pointerPolicy: .init(
                    types: [.touch, .mouse],
                    edges: .horizontal,
                    ignoreWhileScrolling: false,
                    minimumHorizontalEdgeSize: 80,
                    horizontalEdgeThresholdPercent: 0.3
                ),
                keyboardPolicy: .init(handleArrowKeys: true, handleSpaceKey: true),
                animatedTransition: true,
                onNavigation: { Self.log("adapter → page turn") }
            )
            adapter.bind(to: nav)
            directionalAdapter = adapter

            toc = (try? await publication.tableOfContents().get()) ?? []
            Self.log("open OK toc=\(toc.count) bounds=\(nav.view.bounds)")
        } catch {
            loadError = "Couldn’t open book: \(error.localizedDescription)"
            Self.log("open FAILED \(error)")
        }
    }

    func go(to link: ReadiumShared.Link) {
        guard let navigator else { return }
        Task { await navigator.go(to: link) }
    }

    func applyRemoteLocator(json: String) {
        guard let navigator, let locator = Self.locator(fromJSON: json) else { return }
        applyingRemote = true
        Task {
            await navigator.go(to: locator)
            applyingRemote = false
        }
    }

    // MARK: - Page turns

    func goForward() { Task { await turn(forward: true) } }
    func goBackward() { Task { await turn(forward: false) } }

    private func turn(forward: Bool) async {
        guard let navigator else {
            Self.log("turn ignored — no navigator")
            return
        }
        guard !turnInFlight else {
            Self.log("turn ignored — in flight")
            return
        }
        turnInFlight = true
        defer { turnInFlight = false }

        let before = progressionSnapshot(navigator)
        let scrollInfo = Self.webScrollDiagnostics(in: navigator.view)
        Self.log(
            "turn \(forward ? "FWD" : "BACK") before=\(before) \(scrollInfo) bounds=\(navigator.view.bounds)"
        )

        // Prefer animated=true: Readium uses scrollBy(behavior:'smooth'), which
        // WKWebView honours. animated=false uses 'instant', which often no-ops.
        let options = NavigatorGoOptions(animated: true)
        var ok = forward
            ? await navigator.goForward(options: options)
            : await navigator.goBackward(options: options)

        // Allow locationDidChange to settle.
        try? await Task.sleep(for: .milliseconds(50))
        var after = progressionSnapshot(navigator)

        if ok && after ~= before {
            // goForward returned true but nothing moved — force UIKit scroll.
            Self.log("turn no-op after goForward; trying UIKit contentOffset")
            if Self.nudgeWebScroll(in: navigator.view, forward: forward) {
                try? await Task.sleep(for: .milliseconds(80))
                after = progressionSnapshot(navigator)
            }
        }

        if after ~= before {
            // Still stuck: unanimated retry (spine jump path may work when
            // within-resource scroll is at the end).
            ok = forward
                ? await navigator.goForward(options: NavigatorGoOptions(animated: false))
                : await navigator.goBackward(options: NavigatorGoOptions(animated: false))
            try? await Task.sleep(for: .milliseconds(80))
            after = progressionSnapshot(navigator)
        }

        Self.log(
            "turn \(forward ? "FWD" : "BACK") done ok=\(ok) before=\(before) after=\(after) moved=\(!(after ~= before))"
        )
    }

    /// Stable fingerprint of the current location for no-op detection.
    private func progressionSnapshot(_ navigator: EPUBNavigatorViewController) -> String {
        guard let loc = navigator.currentLocation else { return "nil" }
        let prog = loc.locations.progression.map { String(format: "%.5f", $0) } ?? "?"
        let total = loc.locations.totalProgression.map { String(format: "%.5f", $0) } ?? "?"
        return "\(loc.href)#p=\(prog)#t=\(total)"
    }

    // MARK: WebKit scroll helpers

    private static func webScrollDiagnostics(in root: UIView) -> String {
        guard let sv = firstScrollView(in: root) else { return "scrollView=nil" }
        return "offset.x=\(sv.contentOffset.x) size.w=\(sv.contentSize.width) bounds.w=\(sv.bounds.width)"
    }

    /// Advance one viewport width via UIKit when JS scrollBy is a no-op.
    @discardableResult
    private static func nudgeWebScroll(in root: UIView, forward: Bool) -> Bool {
        guard let sv = firstScrollView(in: root), sv.bounds.width > 1 else { return false }
        let page = sv.bounds.width
        let maxX = max(0, sv.contentSize.width - page)
        guard maxX > 1 else {
            log("UIKit nudge skipped — contentSize.w=\(sv.contentSize.width) (not multi-column?)")
            return false
        }
        let delta = forward ? page : -page
        var x = sv.contentOffset.x + delta
        x = min(max(0, x), maxX)
        // Snap to page boundaries.
        x = (x / page).rounded() * page
        x = min(max(0, x), maxX)
        guard abs(x - sv.contentOffset.x) > 1 else { return false }
        log("UIKit nudge offset \(sv.contentOffset.x) → \(x)")
        sv.setContentOffset(CGPoint(x: x, y: sv.contentOffset.y), animated: true)
        return true
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView {
            // Prefer the web document scroller (large content), not tiny chrome.
            return sv
        }
        var best: UIScrollView?
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) {
                if best == nil || found.contentSize.width > (best?.contentSize.width ?? 0) {
                    best = found
                }
            }
        }
        return best
    }

    // MARK: Reading time

    func startReadingSession() {
        guard sessionStart == nil else { return }
        sessionStart = Date()
    }

    func flushReadingSession() {
        guard let book, let context, let start = sessionStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return }
        book.readingSeconds = (book.readingSeconds ?? 0) + elapsed
        sessionStart = Date()
        markFinishedIfNeeded(book)
        try? context.save()
    }

    func endReadingSession() {
        flushReadingSession()
        sessionStart = nil
    }

    private func markFinishedIfNeeded(_ book: Book) {
        guard book.fractionComplete >= 0.98, book.finishedAt == nil else { return }
        book.finishedAt = Date()
    }

    // MARK: Locator

    private func persist(_ locator: Locator) {
        guard let book, let context else { return }
        let newJSON = try? locator.jsonString()
        let changed = newJSON != nil && newJSON != book.readingLocator
        if changed && !applyingRemote {
            book.progressUpdatedAt = Date()
        }
        book.readingLocator = newJSON
        markFinishedIfNeeded(book)
        try? context.save()
        if changed && !applyingRemote {
            let p = locator.locations.progression.map { String(format: "%.4f", $0) } ?? "?"
            Self.log("locator moved progression=\(p)")
            onProgressChanged?()
        }
    }

    private static func locator(fromJSON json: String) -> Locator? {
        guard let value = try? JSONValue(jsonString: json, warnings: nil) else { return nil }
        return try? Locator(json: value, warnings: nil)
    }

    static func log(_ message: String) {
        #if DEBUG
        print("RHAPSODE-READER: \(message)")
        #endif
    }
}

extension EbookReader: EPUBNavigatorDelegate {
    func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        persist(locator)
    }

    func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        loadError = "Reader error: \(error)"
        Self.log("navigator error \(error)")
    }
}
