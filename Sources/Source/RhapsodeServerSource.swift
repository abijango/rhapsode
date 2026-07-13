import Foundation

/// `LibrarySource` over rhapsode-server.
///
/// Synthetic folder layout matches DropboxConfig so `SyncManager` keeps working:
///   `/Audiobooks` — audio items (each entry is one downloadable book file)
///   `/Books` — EPUB items
///
/// Local dest path: `Audiobooks/{itemId}/{filename}` so progress can recover `itemId`.
actor RhapsodeServerSource: LibrarySource {
    private let client: RhapsodeServerClient

    init(client: RhapsodeServerClient = RhapsodeServerClient()) {
        self.client = client
    }

    /// Shared client for progress sync (same token / base URL).
    var sharedClient: RhapsodeServerClient { client }

    func authenticate() async throws {
        try await client.authenticate()
    }

    func listFolder(_ path: String) async throws -> [RemoteEntry] {
        guard let fk = folderKind(for: path) else { return [] }
        return try await listCatalog(kind: fk).map { $0.asRemoteEntry() }
    }

    /// Metadata catalogue for selective download (title/author + paths). No file bytes.
    /// Prefers fat `GET /v1/library` (includes `primary_file`) — one round trip per kind.
    func listCatalog(kind folderKind: FolderKind? = nil) async throws -> [RemoteCatalogEntry] {
        try await client.authenticate()
        let kinds: [FolderKind]
        if let folderKind {
            kinds = [folderKind]
        } else {
            kinds = [.audiobooks, .books]
        }
        var out: [RemoteCatalogEntry] = []
        for fk in kinds {
            let apiKind = fk == .audiobooks ? "audio" : "ebook"
            let root = fk == .audiobooks ? DropboxConfig.audiobooksPath : DropboxConfig.booksPath
            let items = try await client.listLibrary(kind: apiKind)
            for item in items {
                if item.missing { continue }
                let primary: RhapsodeServerClient.PrimaryFile
                if let p = item.primaryFile {
                    primary = p
                } else {
                    // Older servers without fat list — fall back to per-item files.
                    let files = try await client.listFiles(itemId: item.id)
                    let role = fk == .audiobooks ? "audio" : "ebook"
                    guard let p = files.filter({ $0.role == role })
                        .sorted(by: { $0.sortOrder < $1.sortOrder })
                        .first else { continue }
                    primary = RhapsodeServerClient.PrimaryFile(
                        id: p.id, role: p.role, name: p.name,
                        sizeBytes: p.sizeBytes, sortOrder: p.sortOrder)
                }
                let fileName = primary.name
                let lower = fileName.lowercased()
                switch fk {
                case .audiobooks:
                    guard lower.hasSuffix(".m4b") || lower.hasSuffix(".mp3") else { continue }
                case .books:
                    guard lower.hasSuffix(".epub") else { continue }
                }
                let remotePath = "\(root)/\(item.id)/\(primary.id)"
                let localRel = (fk == .audiobooks ? "Audiobooks/" : "Books/")
                    + "\(item.id)/\(fileName)"
                let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(RemoteCatalogEntry(
                    id: "\(item.id):\(primary.id)",
                    kind: fk,
                    title: title.isEmpty ? fileName : title,
                    author: item.author,
                    remotePath: remotePath,
                    localRelPath: localRel,
                    sizeBytes: primary.sizeBytes ?? 0,
                    serverItemId: item.id,
                    fileName: fileName
                ))
            }
        }
        return out
    }

    private func folderKind(for path: String) -> FolderKind? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        switch normalized {
        case DropboxConfig.audiobooksPath, "/Audiobooks": return .audiobooks
        case DropboxConfig.booksPath, "/Books": return .books
        default: return nil
        }
    }

    func changes(since cursor: String?) async throws -> (entries: [RemoteEntry], cursor: String) {
        // No delta API yet — full re-list; SyncManager dedups by import path.
        let audio = try await listFolder(DropboxConfig.audiobooksPath)
        let books = try await listFolder(DropboxConfig.booksPath)
        let stamp = ISO8601DateFormatter().string(from: Date())
        return (audio + books, stamp)
    }

    func longpoll(cursor: String) async throws -> Bool {
        // No longpoll — sleep then report "maybe changes" so watcher re-lists periodically.
        try await Task.sleep(nanoseconds: 30_000_000_000)
        return !Task.isCancelled
    }

    func download(_ entry: RemoteEntry, to destination: URL) async throws {
        let (itemId, fileId) = try Self.parsePath(entry.path)
        try await client.downloadFile(itemId: itemId, fileId: fileId, to: destination)
    }

    /// Background download request for `BackgroundDownloader`.
    func downloadRequest(for remotePath: String) async throws -> URLRequest {
        let (itemId, fileId) = try Self.parsePath(remotePath)
        _ = try await client.resolveBaseURL()
        return try await client.downloadRequest(itemId: itemId, fileId: fileId)
    }

    func ensureFolderExists(_ path: String) async throws {
        // Server owns the library — nothing to create.
    }

    func latestCursor(_ path: String) async throws -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    /// Path shape: `/Audiobooks/{itemId}/{fileId}` or `/Books/...`
    static func parsePath(_ path: String) throws -> (itemId: String, fileId: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3 else {
            throw LibrarySourceError.notFound(path: path)
        }
        return (parts[parts.count - 2], parts[parts.count - 1])
    }

    /// Extract server item id from a local media relative path `Audiobooks/{itemId}/file.m4b`.
    static func itemId(fromLocalRelPath rel: String) -> String? {
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        return parts[1]
    }
}
