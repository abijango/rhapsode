import Foundation
import SwiftData
import SwiftUI
import WebKit

// MARK: - Shared reader surface (progress sync)

/// Minimal surface SyncManager needs for an open ebook reader.
@MainActor
protocol ActiveEbookReader: AnyObject {
    func applyRemoteLocator(json: String)
}

// MARK: - TOC

struct FoliateTOCItem: Identifiable, Hashable {
    var id: String { href + "|" + label }
    let label: String
    let href: String
    let depth: Int
}

// MARK: - Progress JSON (stored in Book.readingLocator)

/// Foliate progress blob. `locations.totalProgression` keeps `Book.fractionComplete` working.
struct FoliateProgress: Codable, Equatable {
    var engine: String = "foliate"
    var cfi: String?
    var locations: Locations
    /// Last KOSync wire `progress` string (XPointer or CFI) for faithful re-push.
    var kosyncProgress: String? = nil

    struct Locations: Codable, Equatable {
        var totalProgression: Double
    }

    var jsonString: String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        guard let data = try? enc.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parse(_ json: String) -> FoliateProgress? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FoliateProgress.self, from: data)
    }

    /// Read totalProgression from either Foliate or legacy Readium locator JSON.
    static func fraction(fromLocatorJSON json: String?) -> Double? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = obj["locations"] as? [String: Any] else { return nil }
        if let d = locations["totalProgression"] as? Double { return d }
        if let n = locations["totalProgression"] as? NSNumber { return n.doubleValue }
        return nil
    }

    static func cfi(fromLocatorJSON json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let engine = obj["engine"] as? String, engine == "foliate",
           let cfi = obj["cfi"] as? String, !cfi.isEmpty {
            return cfi
        }
        return nil
    }
}

// MARK: - Reader

/// EPUB reader powered by foliate-js inside a single WKWebView.
@MainActor
@Observable
final class FoliateWebReader: NSObject, ActiveEbookReader {
    /// Shared process pool so successive books reuse WebKit warm state.
    private static let processPool = WKProcessPool()

    private(set) var isReady = false
    private(set) var isOpen = false
    private(set) var loadError: String?
    /// Lightweight status for the opening chrome (“Parsing book…”).
    private(set) var openingStatus: String?
    private(set) var toc: [FoliateTOCItem] = []
    private(set) var webView: WKWebView?

    var settings = ReaderSettings.fromPreferences() {
        didSet {
            guard settings != oldValue else { return }
            settings.saveToPreferences()
            pushStyles()
        }
    }

    var onProgressChanged: (() -> Void)?
    var onChromeToggle: (() -> Void)?

    private let scheme = FoliateSchemeHandler()
    private var book: Book?
    private var context: ModelContext?
    private var sessionStart: Date?
    private var applyingRemote = false
    private var remoteApplyGeneration = 0
    private var openGeneration = 0
    private var saveTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    /// Resumed by the `opened` / `error` script message (not by `callAsyncJavaScript`).
    private var openContinuation: CheckedContinuation<Void, Never>?

    // MARK: Lifecycle

    func prepareWebViewIfNeeded() {
        guard webView == nil else { return }

        let userContent = WKUserContentController()
        userContent.add(self, name: "rhapsode")

        let config = WKWebViewConfiguration()
        config.processPool = Self.processPool
        config.userContentController = userContent
        config.setURLSchemeHandler(scheme, forURLScheme: FoliateSchemeHandler.scheme)
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        // Faster first paint for long HTML sections.
        config.suppressesIncrementalRendering = false
        // Keep media from autoplaying if a book embeds it.
        config.mediaTypesRequiringUserActionForPlayback = .all

        let wv = WKWebView(frame: .zero, configuration: config)
        // Opaque + matching scroll backdrop avoids “half dark / half light” under the page.
        wv.isOpaque = true
        wv.backgroundColor = .black
        wv.scrollView.backgroundColor = .black
        wv.scrollView.isScrollEnabled = false
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = self
        #if DEBUG
        if #available(iOS 16.4, *) {
            wv.isInspectable = true
        }
        #endif
        webView = wv

        let url = URL(string: "\(FoliateSchemeHandler.scheme)://reader/index.html")!
        wv.load(URLRequest(url: url))
        Self.log("loading shell \(url.absoluteString)")
    }

    /// Touch WebKit + process pool early (Books shelf) so first open pays less cold-start cost.
    private static var didWarm = false
    static func warmProcessPool() {
        guard !didWarm else { return }
        didWarm = true
        // Creating a throwaway configuration with the shared pool primes WebKit without a full shell.
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        _ = WKWebView(frame: .zero, configuration: config)
        log("process pool warmed")
    }

    func open(_ book: Book, context: ModelContext) async {
        openGeneration += 1
        let generation = openGeneration

        self.book = book
        self.context = context
        loadError = nil
        isOpen = false
        toc = []
        openingStatus = "Opening…"
        Self.log("open start “\(book.title)”")

        prepareWebViewIfNeeded()

        do {
            let fileURL = try ContainerPaths.url(forRelativePath: book.fileRelPath)
            if let err = EPUBFileValidator.validateLocalEPUB(at: fileURL) {
                guard generation == openGeneration else { return }
                loadError = err
                openingStatus = nil
                return
            }

            scheme.bookFileURL = fileURL

            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if fileSize > 30 * 1024 * 1024 {
                openingStatus = "Large book — this may take a moment…"
            }

            let shellOK = await waitForShellReady(timeout: .seconds(8))
            guard generation == openGeneration else { return }
            guard shellOK else {
                if loadError == nil {
                    loadError = "Reader shell failed to load. Restart the app and try again."
                }
                openingStatus = nil
                return
            }

            guard let webView else {
                loadError = "Reader web view failed to start."
                openingStatus = nil
                return
            }

            // callAsyncJavaScript can hang forever if the view is not in a window.
            await waitForWebViewLayout(timeout: .seconds(4))
            guard generation == openGeneration else { return }

            openingStatus = "Parsing book…"

            let cfi = FoliateProgress.cfi(fromLocatorJSON: book.readingLocator)
            let fraction = FoliateProgress.fraction(fromLocatorJSON: book.readingLocator)

            var opts: [String: Any] = [
                "bookURL": "\(FoliateSchemeHandler.scheme)://book/book.epub",
                "name": (book.fileRelPath as NSString).lastPathComponent,
                "settings": settingsDictionary(),
            ]
            if let fraction, fraction > 0 { opts["fraction"] = fraction }
            if let cfi { opts["cfi"] = cfi }

            let json = try Self.jsonString(from: opts)
            // Do NOT `await callAsyncJavaScript("return await __rhapsode.open")`.
            // `open()` postMessage()s back (`log` / `opened` / `error`) on the same
            // WK IPC as the async-JS completion, so the promise never resolves and
            // the overlay stays on "Opening…" forever.
            Self.log("kicking open \(opts["name"] ?? "")")
            webView.evaluateJavaScript("void window.__rhapsode.open(\(json))") { _, error in
                if let error {
                    Self.log("open evaluate failed: \(error.localizedDescription)")
                    Task { @MainActor in
                        guard generation == self.openGeneration else { return }
                        if self.openContinuation != nil {
                            self.loadError = Self.friendlyOpenError(error.localizedDescription)
                            self.openingStatus = nil
                            self.resumeOpenWait()
                        }
                    }
                }
            }

            let opened = await waitForBookOpened(timeout: .seconds(90))
            guard generation == openGeneration else { return }

            if opened {
                openingStatus = nil
                loadError = nil
                Self.log("open OK “\(book.title)”")
            } else if loadError == nil {
                loadError = "Opening this book took too long. Try again."
                openingStatus = nil
                Self.log("open timed out")
            } else {
                openingStatus = nil
                Self.log("open JS reported failure: \(loadError ?? "")")
            }
        } catch {
            guard generation == openGeneration else { return }
            loadError = Self.friendlyOpenError(error.localizedDescription)
            openingStatus = nil
            Self.log("open FAILED \(error)")
            resumeOpenWait()
        }
    }

    /// Cancel an in-flight open (e.g. user pops the reader before parse finishes).
    func cancelOpen() {
        openGeneration += 1
        openingStatus = nil
        resumeOpenWait()
    }

    /// Tear down the open book, release JS heap memory, and drop the EPUB scheme binding.
    func destroy() {
        openGeneration += 1
        openingStatus = nil
        resumeOpenWait()
        turnTask?.cancel()
        turnTask = nil
        isOpen = false
        toc = []
        book = nil
        scheme.bookFileURL = nil
        let wv = webView
        wv?.evaluateJavaScript("void window.__rhapsode?.destroy?.()", completionHandler: nil)
    }

    /// Wait until the shell posts `ready`, or until timeout. Returns whether `isReady`.
    private func waitForShellReady(timeout: Duration) async -> Bool {
        if isReady { return true }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            readyContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if let c = self.readyContinuation {
                    self.readyContinuation = nil
                    c.resume()
                }
            }
        }
        return isReady
    }

    /// WKWebView JS evaluation can hang if the view has no window / zero size.
    private func waitForWebViewLayout(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let wv = webView, wv.window != nil, wv.bounds.width > 8, wv.bounds.height > 8 {
                return
            }
            try? await Task.sleep(for: .milliseconds(32))
        }
        Self.log("layout wait timed out bounds=\(String(describing: webView?.bounds)) window=\(webView?.window != nil)")
    }

    /// Completes when the bridge posts `opened` or `error`, or when `timeout` elapses.
    private func waitForBookOpened(timeout: Duration) async -> Bool {
        if isOpen { return true }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            openContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                if let c = self.openContinuation {
                    self.openContinuation = nil
                    c.resume()
                }
            }
        }
        return isOpen
    }

    private func resumeOpenWait() {
        if let c = openContinuation {
            openContinuation = nil
            c.resume()
        }
    }

    private static func jsonString(from object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let s = String(data: data, encoding: .utf8) else {
            throw CocoaError(.coderInvalidValue)
        }
        return s
    }

    private static func friendlyOpenError(_ raw: String?) -> String {
        let msg = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if msg.isEmpty { return "Couldn’t open this book." }
        if msg.localizedCaseInsensitiveContains("not a valid EPUB")
            || msg.localizedCaseInsensitiveContains("corrupt") {
            return msg
        }
        if msg.localizedCaseInsensitiveContains("empty")
            || msg.localizedCaseInsensitiveContains("missing") {
            return msg
        }
        if msg.localizedCaseInsensitiveContains("JavaScript")
            || msg.localizedCaseInsensitiveContains("undefined is not") {
            return "Reader failed to start. Restart the app and try again."
        }
        return msg
    }

    // MARK: Navigation

    func goForward() {
        guard isOpen else { return }
        turnTask?.cancel()
        turnTask = Task {
            _ = try? await webView?.callAsyncJavaScript(
                "return window.__rhapsode.next()",
                contentWorld: .page
            )
        }
    }

    func goBackward() {
        guard isOpen else { return }
        turnTask?.cancel()
        turnTask = Task {
            _ = try? await webView?.callAsyncJavaScript(
                "return window.__rhapsode.prev()",
                contentWorld: .page
            )
        }
    }

    func go(to item: FoliateTOCItem) {
        guard isOpen else { return }
        Task {
            _ = try? await webView?.callAsyncJavaScript(
                "return await window.__rhapsode.goTo(target)",
                arguments: ["target": ["href": item.href]],
                contentWorld: .page
            )
        }
    }

    func applyRemoteLocator(json: String) {
        remoteApplyGeneration += 1
        let generation = remoteApplyGeneration
        applyingRemote = true
        Task {
            defer {
                if generation == remoteApplyGeneration {
                    applyingRemote = false
                }
            }
            var target: [String: Any] = [:]
            if let cfi = FoliateProgress.cfi(fromLocatorJSON: json) {
                target["cfi"] = cfi
            } else if let fraction = FoliateProgress.fraction(fromLocatorJSON: json) {
                target["fraction"] = fraction
            } else {
                return
            }
            _ = try? await webView?.callAsyncJavaScript(
                "return await window.__rhapsode.goTo(target)",
                arguments: ["target": target],
                contentWorld: .page
            )
        }
    }

    /// Jump by overall fraction (0…1) — used for KOSync XPointer reports.
    func applyRemoteFraction(_ fraction: Double) {
        remoteApplyGeneration += 1
        let generation = remoteApplyGeneration
        applyingRemote = true
        let f = min(1, max(0, fraction))
        Task {
            defer {
                if generation == remoteApplyGeneration {
                    applyingRemote = false
                }
            }
            _ = try? await webView?.callAsyncJavaScript(
                "return await window.__rhapsode.goTo(target)",
                arguments: ["target": ["fraction": f]],
                contentWorld: .page
            )
        }
    }

    // MARK: Settings

    /// Theme + data-driven font catalog payload for the Foliate bridge.
    private func settingsDictionary() -> [String: Any] {
        let preset = settings.fontChoice.preset
        var dict: [String: Any] = [
            "theme": settings.theme.rawValue,
            "fontSize": settings.fontSize,
            // Legacy key kept for older bridge builds.
            "fontFamily": preset.id,
        ]
        for (k, v) in preset.bridgePayload() {
            dict[k] = v
        }
        return dict
    }

    private func pushStyles() {
        guard isOpen, let webView else { return }
        let styles = settingsDictionary()
        Task {
            _ = try? await webView.callAsyncJavaScript(
                "return window.__rhapsode.setStyles(settings)",
                arguments: ["settings": styles],
                contentWorld: .page
            )
        }
    }

    // MARK: Reading time

    func startReadingSession() {
        guard sessionStart == nil else { return }
        sessionStart = Date()
    }

    func flushReadingSession() {
        guard let book, let start = sessionStart else { return }
        let elapsed = Date().timeIntervalSince(start)
        guard elapsed > 0 else { return }
        book.readingSeconds = (book.readingSeconds ?? 0) + elapsed
        sessionStart = Date()
        markFinishedIfNeeded(book)
        flushPendingSave()
    }

    func endReadingSession() {
        flushReadingSession()
        sessionStart = nil
        flushPendingSave()
    }

    private func markFinishedIfNeeded(_ book: Book) {
        guard book.fractionComplete >= 0.98, book.finishedAt == nil else { return }
        book.finishedAt = Date()
    }

    // MARK: Persist

    private func persist(cfi: String?, fraction: Double) {
        guard let book else { return }
        // Keep last KOSync wire string (e.g. XPointer from another device) only until
        // the user moves; local CFI becomes the new wire progress on next push.
        let progress = FoliateProgress(
            cfi: cfi,
            locations: .init(totalProgression: min(1, max(0, fraction))),
            kosyncProgress: nil
        )
        let newJSON = progress.jsonString
        let changed = newJSON != nil && newJSON != book.readingLocator
        if changed && !applyingRemote {
            book.progressUpdatedAt = Date()
        }
        book.readingLocator = newJSON
        markFinishedIfNeeded(book)
        scheduleDebouncedSave()
        if changed && !applyingRemote {
            onProgressChanged?()
        }
    }

    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        saveNow()
    }

    private func saveNow() {
        guard let context else { return }
        do {
            try context.save()
        } catch {
            Self.log("save failed: \(error.localizedDescription)")
        }
    }

    nonisolated static func log(_ message: String) {
        #if DEBUG
        print("RHAPSODE-FOLIATE: \(message)")
        #endif
    }
}

// MARK: - WKScriptMessageHandler

extension FoliateWebReader: WKScriptMessageHandler {
    /// Hop off the WebKit callback immediately. Handling on MainActor synchronously
    /// while JS is mid-`postMessage` is how `callAsyncJavaScript` deadlocks.
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == "rhapsode",
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let snapshot = ScriptMessage(type: type, body: body)
        Task { @MainActor in
            self.handleScriptMessage(snapshot)
        }
    }

    private func handleScriptMessage(_ message: ScriptMessage) {
        switch message.type {
        case "ready":
            isReady = true
            if let c = readyContinuation {
                readyContinuation = nil
                c.resume()
            }
            Self.log("shell ready")

        case "opened":
            if let items = message.body["toc"] as? [[String: Any]] {
                toc = items.compactMap { item in
                    guard let label = item["label"] as? String,
                          let href = item["href"] as? String else { return nil }
                    let depth = item["depth"] as? Int ?? 0
                    return FoliateTOCItem(label: label, href: href, depth: depth)
                }
            }
            isOpen = true
            Self.log("opened toc=\(toc.count)")
            resumeOpenWait()

        case "relocate":
            let cfi = message.body["cfi"] as? String
            let fraction: Double
            if let d = message.body["fraction"] as? Double {
                fraction = d
            } else if let n = message.body["fraction"] as? NSNumber {
                fraction = n.doubleValue
            } else {
                fraction = 0
            }
            persist(cfi: cfi, fraction: fraction)

        case "error":
            let msg = message.body["message"] as? String ?? "Unknown reader error"
            loadError = msg
            Self.log("error \(msg)")
            resumeOpenWait()

        case "log":
            if let msg = message.body["message"] as? String {
                Self.log(msg)
            }

        case "chromeToggle":
            onChromeToggle?()

        default:
            break
        }
    }
}

/// Snapshot of a `webkit.messageHandlers` payload. Copied off the WK message
/// so the handler can hop to MainActor without retaining `WKScriptMessage`.
private struct ScriptMessage: @unchecked Sendable {
    let type: String
    let body: [String: Any]
}

// MARK: - WKNavigationDelegate

extension FoliateWebReader: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = "Reader shell failed: \(error.localizedDescription)"
        Self.log("nav fail \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = "Reader shell failed: \(error.localizedDescription)"
        Self.log("nav provisional fail \(error)")
    }
}
