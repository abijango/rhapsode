import CryptoKit
import Foundation

/// `ProgressSync` over the Dropbox app folder: one small JSON file per item under
/// `/.rhapsode-sync/`, named by a stable hash of the item key. Requires the
/// `files.content.write` scope (see `DropboxConfig.scopes`).
///
/// Why Dropbox and not CloudKit: progress must live somewhere every device reads,
/// and the Dropbox app folder ports to the planned Android client unchanged (plain
/// HTTP + JSON), whereas CloudKit is Apple-only and needs a paid account. The cost
/// is a wider scope (app-folder write only — still narrow, not Full Dropbox).
struct DropboxProgressSync: ProgressSync {
    /// Hidden-ish sibling of `/Audiobooks` and `/Books`. The library scan only
    /// looks in those two roots, so progress files are never mistaken for content.
    static let folder = "/.rhapsode-sync"

    let source: DropboxSource

    func push(_ progress: PlaybackProgress) async throws {
        let path = Self.path(for: progress.key)
        // Read-before-write LWW guard: never clobber a strictly-newer remote record
        // (e.g. another device wrote after our last pull). The content `updatedAt`
        // is the arbiter, not Dropbox's file-level last-writer.
        if let data = try? await source.readFile(at: path),
           let existing = try? PlaybackProgress.decoder.decode(PlaybackProgress.self, from: data),
           existing.updatedAt > progress.updatedAt {
            return
        }
        let data = try PlaybackProgress.encoder.encode(progress)
        try await source.writeFile(data, to: path)
    }

    func pullAll() async throws -> [PlaybackProgress] {
        // The sync folder may not exist yet (first device, before any push). A
        // missing folder lists as path/not_found → treat as "no progress yet".
        let entries: [RemoteEntry]
        do {
            entries = try await source.listFolder(Self.folder)
        } catch {
            return []
        }
        var result: [PlaybackProgress] = []
        for entry in entries where !entry.isFolder && entry.name.hasSuffix(".json") {
            if let data = try? await source.readFile(at: entry.path),
               let p = try? PlaybackProgress.decoder.decode(PlaybackProgress.self, from: data) {
                result.append(p)
            }
        }
        return result
    }

    /// Stable, ASCII, filesystem-safe file path for an item key (SHA-256 hex). The
    /// real key lives inside the JSON, so the hashed name only needs to be a stable
    /// unique handle — identical for the same key on every device.
    static func path(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(folder)/\(hex).json"
    }
}
