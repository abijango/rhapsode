import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled ReaderWeb shell + foliate-js, and the currently open EPUB,
/// under the custom `rhapsode` URL scheme so ES modules and `fetch` work inside WKWebView.
///
/// Layout:
///   rhapsode://reader/index.html
///   rhapsode://reader/bridge.js
///   rhapsode://reader/foliate-js/view.js
///   rhapsode://reader/fonts/Literata-Regular.ttf  → bundled ReaderFonts
///   rhapsode://book/book.epub                     → `bookFileURL` (streamed for large files)
final class FoliateSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "rhapsode"

    /// Absolute file URL of the EPUB currently being read (set before `open`).
    var bookFileURL: URL?

    private let readerRoot: URL
    private let foliateRoot: URL
    private let fontsRoot: URL?

    /// Chunk size when streaming large EPUB bytes to WKWebView (256 KiB).
    private static let streamChunk = 256 * 1024
    /// Files larger than this are streamed instead of fully buffered.
    private static let streamThreshold: Int64 = 2 * 1024 * 1024

    override init() {
        let bundle = Bundle.main
        if let url = bundle.resourceURL?.appendingPathComponent("ReaderWeb", isDirectory: true),
           FileManager.default.fileExists(atPath: url.path) {
            readerRoot = url
        } else if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: "ReaderWeb")?
            .deletingLastPathComponent() {
            readerRoot = url
        } else if let url = bundle.url(forResource: "index", withExtension: "html")?.deletingLastPathComponent() {
            readerRoot = url
        } else {
            readerRoot = bundle.bundleURL
        }

        let candidates = [
            bundle.resourceURL?.appendingPathComponent("foliate-js", isDirectory: true),
            readerRoot.appendingPathComponent("foliate-js", isDirectory: true),
            bundle.resourceURL?.appendingPathComponent("Vendor/foliate-js", isDirectory: true),
        ].compactMap { $0 }
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            foliateRoot = url
        } else {
            foliateRoot = readerRoot.appendingPathComponent("foliate-js", isDirectory: true)
        }

        if let sub = bundle.resourceURL?.appendingPathComponent("ReaderFonts", isDirectory: true),
           FileManager.default.fileExists(atPath: sub.path) {
            fontsRoot = sub
        } else {
            fontsRoot = bundle.resourceURL
        }
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(SchemeError.badURL)
            return
        }

        let host = (url.host ?? "").lowercased()
        let path = url.path

        do {
            switch host {
            case "reader":
                try serveReader(path: path, task: urlSchemeTask, requestURL: url)
            case "book":
                try serveBook(task: urlSchemeTask, requestURL: url)
            default:
                throw SchemeError.notFound(url.absoluteString)
            }
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Streaming is synchronous on the callback; nothing to cancel mid-chunk.
    }

    // MARK: - Serve

    private func serveReader(path: String, task: any WKURLSchemeTask, requestURL: URL) throws {
        var relative = path
        if relative.hasPrefix("/") { relative.removeFirst() }
        if relative.isEmpty { relative = "index.html" }

        let fileURL: URL
        if relative.hasPrefix("foliate-js/") {
            let rest = String(relative.dropFirst("foliate-js/".count))
            fileURL = foliateRoot.appendingPathComponent(rest)
        } else if relative.hasPrefix("fonts/") {
            let name = String(relative.dropFirst("fonts/".count))
            guard let resolved = resolveFont(named: name) else {
                throw SchemeError.notFound("fonts/\(name)")
            }
            fileURL = resolved
        } else {
            fileURL = readerRoot.appendingPathComponent(relative)
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SchemeError.notFound(fileURL.path)
        }

        let mime = mimeType(for: fileURL)
        let cache = relative.hasPrefix("fonts/") || relative.hasPrefix("foliate-js/")
            ? "public, max-age=604800"
            : "no-cache"
        // Mapped I/O for modules/fonts — avoids an extra full buffer when the kernel can.
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        respond(task: task, requestURL: requestURL, data: data, mime: mime, cacheControl: cache)
    }

    private func resolveFont(named name: String) -> URL? {
        // User imports: rhapsode://reader/fonts/custom/<uuid>.ttf → Application Support.
        if name.hasPrefix("custom/") {
            let file = String(name.dropFirst("custom/".count))
            // Prevent path traversal.
            guard !file.contains(".."), !file.contains("/") else { return nil }
            let rel = "ReaderFonts/Custom/\(file)"
            if let url = try? ContainerPaths.url(forRelativePath: rel),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            return nil
        }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        if let fontsRoot {
            let candidate = fontsRoot.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if !ext.isEmpty, let url = Bundle.main.url(forResource: base, withExtension: ext) {
            return url
        }
        return Bundle.main.url(forResource: base, withExtension: "ttf")
    }

    private func serveBook(task: any WKURLSchemeTask, requestURL: URL) throws {
        guard let bookFileURL else { throw SchemeError.noBook }
        guard FileManager.default.fileExists(atPath: bookFileURL.path) else {
            throw SchemeError.notFound(bookFileURL.path)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: bookFileURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mime = "application/epub+zip"

        if size > Self.streamThreshold {
            try streamFile(
                at: bookFileURL,
                size: size,
                mime: mime,
                task: task,
                requestURL: requestURL,
                cacheControl: "no-store"
            )
        } else {
            let data = try Data(contentsOf: bookFileURL, options: [.mappedIfSafe])
            respond(
                task: task,
                requestURL: requestURL,
                data: data,
                mime: mime,
                cacheControl: "no-store"
            )
        }
    }

    /// Stream a large file to the webview in chunks so we don't pin a multi-hundred-MB buffer.
    private func streamFile(
        at fileURL: URL,
        size: Int64,
        mime: String,
        task: any WKURLSchemeTask,
        requestURL: URL,
        cacheControl: String
    ) throws {
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(size)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": cacheControl,
        ]
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            throw SchemeError.badURL
        }
        task.didReceive(response)

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        while true {
            let chunk: Data?
            if #available(iOS 13.4, *) {
                chunk = try handle.read(upToCount: Self.streamChunk)
            } else {
                chunk = handle.readData(ofLength: Self.streamChunk)
            }
            guard let chunk, !chunk.isEmpty else { break }
            task.didReceive(chunk)
        }
        task.didFinish()
    }

    private func respond(
        task: any WKURLSchemeTask,
        requestURL: URL,
        data: Data,
        mime: String,
        cacheControl: String = "no-cache"
    ) {
        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": "\(data.count)",
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": cacheControl,
        ]
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            task.didFailWithError(SchemeError.badURL)
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        case "map": return "application/json"
        default:
            if let ut = UTType(filenameExtension: url.pathExtension),
               let mime = ut.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }
    }

    enum SchemeError: LocalizedError {
        case badURL
        case notFound(String)
        case noBook

        var errorDescription: String? {
            switch self {
            case .badURL: "Invalid reader URL"
            case .notFound(let p): "Reader resource missing: \(p)"
            case .noBook: "No book file set for rhapsode://book"
            }
        }
    }
}
