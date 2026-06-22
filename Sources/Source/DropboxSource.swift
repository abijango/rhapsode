import Foundation

/// `LibrarySource` backed by the Dropbox HTTP API (no SDK), App-folder access.
/// Uses `files/list_folder`, `.../continue`, `.../longpoll`, and `files/download`.
/// Tokens live in the Keychain; the short-lived access token is refreshed on demand.
///
/// An `actor` so token refresh is serialized and the type is safely `Sendable`.
actor DropboxSource: LibrarySource {
    private let keychain: KeychainTokenStore
    private let session: URLSession
    private var tokens: DropboxTokens?

    init(keychain: KeychainTokenStore = KeychainTokenStore(), session: URLSession = .shared) {
        self.keychain = keychain
        self.session = session
    }

    // MARK: LibrarySource

    func authenticate() async throws {
        if tokens == nil { tokens = try keychain.load() }
        guard tokens != nil else { throw LibrarySourceError.notAuthenticated }
        _ = try await validAccessToken()
    }

    func listFolder(_ path: String) async throws -> [RemoteEntry] {
        let body = ListFolderArg(path: Self.apiPath(path), recursive: false)
        var page: ListFolderResult = try await rpc("/files/list_folder", body)
        var entries = page.entries
        while page.has_more {
            page = try await rpc("/files/list_folder/continue", ContinueArg(cursor: page.cursor))
            entries += page.entries
        }
        return entries.map(Self.remoteEntry)
    }

    func changes(since cursor: String?) async throws -> (entries: [RemoteEntry], cursor: String) {
        var page: ListFolderResult
        if let cursor {
            page = try await rpc("/files/list_folder/continue", ContinueArg(cursor: cursor))
        } else {
            // Initial sync: recursive listing of the whole app folder.
            page = try await rpc("/files/list_folder", ListFolderArg(path: "", recursive: true))
        }
        var entries = page.entries
        while page.has_more {
            page = try await rpc("/files/list_folder/continue", ContinueArg(cursor: page.cursor))
            entries += page.entries
        }
        // Skip deletions — the watcher only acts on added/changed files.
        let live = entries.filter { $0.tag != "deleted" }
        return (live.map(Self.remoteEntry), page.cursor)
    }

    func longpoll(cursor: String) async throws -> Bool {
        // The longpoll endpoint is unauthenticated (the cursor is the credential).
        var req = URLRequest(url: URL(string: DropboxConfig.notifyBase + "/files/list_folder/longpoll")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LongpollArg(cursor: cursor, timeout: 30))
        req.timeoutInterval = 60
        let (data, response) = try await session.data(for: req)
        try Self.checkOK(response, data)
        return try JSONDecoder().decode(LongpollResult.self, from: data).changes
    }

    func ensureFolderExists(_ path: String) async throws {
        do {
            let _: CreateFolderResult = try await rpc("/files/create_folder_v2",
                CreateFolderArg(path: Self.apiPath(path), autorename: false))
        } catch let LibrarySourceError.network(underlying) where underlying.contains("path/conflict") {
            // Folder already exists — fine.
        }
    }

    func latestCursor(_ path: String) async throws -> String {
        let result: GetLatestCursorResult = try await rpc(
            "/files/list_folder/get_latest_cursor",
            ListFolderArg(path: Self.apiPath(path), recursive: false))
        return result.cursor
    }

    func download(_ entry: RemoteEntry, to destination: URL) async throws {
        let fm = FileManager.default
        if entry.isFolder {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for child in try await listFolder(entry.path) {
                try await download(child, to: destination.appendingPathComponent(child.name))
            }
            return
        }
        try await downloadFile(path: entry.path, to: destination)
    }

    /// Build a fully authorised `URLRequest` for a background `URLSessionDownloadTask`.
    /// The token is baked in at enqueue time so the background session can execute the
    /// request without calling back into the app to refresh. If the task later fails
    /// with a 401 (long suspension), the caller should re-enqueue with a fresh request.
    func downloadRequest(for path: String) async throws -> URLRequest {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: DropboxConfig.contentBase + "/files/download")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let arg = String(data: try JSONEncoder().encode(DownloadArg(path: path)), encoding: .utf8)!
        req.setValue(Self.asciiEscapeJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        return req
    }

    // MARK: Progress sync (app-folder read/write)

    /// Overwrite a small file in the app folder. Used by `DropboxProgressSync` to
    /// store cross-device progress. Requires the `files.content.write` scope; if the
    /// connected token predates that scope, Dropbox returns a missing-scope error
    /// (surfaced as `.network`) — the caller swallows it until the user reconnects.
    func writeFile(_ data: Data, to path: String) async throws {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: DropboxConfig.contentBase + "/files/upload")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let arg = String(data: try JSONEncoder().encode(
            UploadArg(path: Self.apiPath(path), mode: "overwrite", mute: true, autorename: false)),
                         encoding: .utf8)!
        req.setValue(Self.asciiEscapeJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        let (respData, response) = try await session.upload(for: req, from: data)
        try Self.checkOK(response, respData)
    }

    /// Read a file's bytes from the app folder. Returns nil if it doesn't exist
    /// (Dropbox answers 409 `path/not_found` for a missing download target).
    func readFile(at path: String) async throws -> Data? {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: DropboxConfig.contentBase + "/files/download")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let arg = String(data: try JSONEncoder().encode(DownloadArg(path: Self.apiPath(path))), encoding: .utf8)!
        req.setValue(Self.asciiEscapeJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode == 409 { return nil }
        try Self.checkOK(response, data)
        return data
    }

    // MARK: Token

    private func validAccessToken() async throws -> String {
        if tokens == nil { tokens = try keychain.load() }
        guard let current = tokens else { throw LibrarySourceError.notAuthenticated }
        // Refresh a little early to avoid mid-request expiry.
        if current.accessTokenExpiry.timeIntervalSinceNow < 60 {
            let refreshed = try await DropboxOAuth.refresh(refreshToken: current.refreshToken)
            try keychain.save(refreshed)
            tokens = refreshed
            return refreshed.accessToken
        }
        return current.accessToken
    }

    // MARK: HTTP

    /// JSON-in/JSON-out RPC against `api.dropboxapi.com`.
    private func rpc<Body: Encodable, Result: Decodable>(_ path: String, _ body: Body) async throws -> Result {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: DropboxConfig.apiBase + path)!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        try Self.checkOK(response, data)
        do {
            return try JSONDecoder().decode(Result.self, from: data)
        } catch {
            throw LibrarySourceError.decoding(String(describing: error))
        }
    }

    /// Download endpoint: arg goes in the `Dropbox-API-Arg` header, file bytes come back.
    private func downloadFile(path: String, to destination: URL) async throws {
        let token = try await validAccessToken()
        var req = URLRequest(url: URL(string: DropboxConfig.contentBase + "/files/download")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let arg = String(data: try JSONEncoder().encode(DownloadArg(path: path)), encoding: .utf8)!
        // Dropbox requires the Dropbox-API-Arg header to be pure ASCII; escape any
        // non-ASCII characters (e.g. accented filenames) using JSON \uXXXX sequences.
        req.setValue(Self.asciiEscapeJSON(arg), forHTTPHeaderField: "Dropbox-API-Arg")

        let (tempURL, response) = try await session.download(for: req)
        try Self.checkOK(response, Data())
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tempURL, to: destination)
    }

    // MARK: Mapping / helpers

    /// Dropbox wants "" for the (app-folder) root; subpaths keep their leading slash.
    private static func apiPath(_ path: String) -> String {
        (path == "/" || path.isEmpty) ? "" : path
    }

    private static func remoteEntry(_ e: Metadata) -> RemoteEntry {
        RemoteEntry(
            id: e.id ?? e.path_lower ?? UUID().uuidString,
            name: e.name,
            path: e.path_display ?? e.path_lower ?? "/\(e.name)",
            size: e.size ?? 0,
            isFolder: e.tag == "folder"
        )
    }

    /// Escape any non-ASCII scalar values in a JSON string using `\uXXXX` sequences
    /// so the result is safe to embed in an HTTP header (which must be ASCII per RFC 7230).
    /// Already-ASCII characters and existing escape sequences are passed through unchanged.
    static func asciiEscapeJSON(_ json: String) -> String {
        var out = ""
        out.reserveCapacity(json.utf16.count)
        for scalar in json.unicodeScalars {
            if scalar.value > 127 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static func checkOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LibrarySourceError.network(underlying: "no HTTP response")
        }
        if http.statusCode == 401 { throw LibrarySourceError.notAuthenticated }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LibrarySourceError.network(underlying: "HTTP \(http.statusCode): \(body)")
        }
    }
}

// MARK: - Wire types

private struct ListFolderArg: Encodable { let path: String; let recursive: Bool }
private struct ContinueArg: Encodable { let cursor: String }
private struct CreateFolderArg: Encodable { let path: String; let autorename: Bool }
private struct CreateFolderResult: Decodable { let metadata: Metadata }
private struct GetLatestCursorResult: Decodable { let cursor: String }
private struct DownloadArg: Encodable { let path: String }
private struct UploadArg: Encodable { let path: String; let mode: String; let mute: Bool; let autorename: Bool }
private struct LongpollArg: Encodable { let cursor: String; let timeout: Int }
private struct LongpollResult: Decodable { let changes: Bool }

private struct ListFolderResult: Decodable {
    let entries: [Metadata]
    let cursor: String
    let has_more: Bool
}

/// A Dropbox file/folder metadata entry. `.tag` discriminates file vs folder.
private struct Metadata: Decodable {
    let tag: String?
    let name: String
    let id: String?
    let path_lower: String?
    let path_display: String?
    let size: Int64?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag", name, id, path_lower, path_display, size
    }
}
