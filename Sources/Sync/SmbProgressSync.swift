import CryptoKit
import Foundation

/// `ProgressSync` over an SMB share: one small JSON file per item under the
/// configured sync folder (default `.rhapsode-sync/`), same wire format as
/// `DropboxProgressSync` so keys/LWW match Dropbox/server mental model.
///
/// Paths are relative to the **share root** (not under Audiobooks/Books), so
/// progress files are never ingested as library content.
actor SmbProgressSync: ProgressSync {
    /// Dropbox-style leading slash so `SmbLibrarySource.mapLibraryPath` keeps the
    /// path under the share root (not remapped into Audiobooks/Books).
    static var folder: String {
        let p = SmbConfig.syncPath
        if p.isEmpty { return "/.rhapsode-sync" }
        return p.hasPrefix("/") ? p : "/\(p)"
    }

    static var statsPath: String { "\(folder)/cadence-stats.json" }

    static func collectionsPath(for kind: FolderKind) -> String {
        switch kind {
        case .audiobooks: "\(folder)/collections-audiobooks.json"
        case .books: "\(folder)/collections-books.json"
        }
    }

    private let source: SmbLibrarySource

    init(source: SmbLibrarySource) {
        self.source = source
    }

    func push(_ progress: PlaybackProgress) async throws {
        let path = Self.path(for: progress.key)
        if let data = try? await source.readFile(at: path),
           let existing = try? PlaybackProgress.decoder.decode(PlaybackProgress.self, from: data),
           existing.updatedAt > progress.updatedAt {
            return
        }
        let data = try PlaybackProgress.encoder.encode(progress)
        try await source.writeFile(data, to: path)
    }

    func pullAll() async throws -> [PlaybackProgress] {
        let entries: [RemoteEntry]
        do {
            entries = try await source.listFolder(Self.folder)
        } catch {
            return []
        }
        var result: [PlaybackProgress] = []
        for entry in entries where !entry.isFolder && entry.name.lowercased().hasSuffix(".json") {
            // Skip shared stats/collections manifests.
            let name = entry.name.lowercased()
            if name == "cadence-stats.json"
                || name.hasPrefix("collections-") { continue }
            if let data = try? await source.readFile(at: entry.path),
               let p = try? PlaybackProgress.decoder.decode(PlaybackProgress.self, from: data) {
                result.append(p)
            }
        }
        return result
    }

    func pushStats(_ stats: SmartSpeechStatsRecord) async throws {
        if let data = try? await source.readFile(at: Self.statsPath),
           let existing = try? PlaybackProgress.decoder.decode(SmartSpeechStatsRecord.self, from: data),
           existing.updatedAt > stats.updatedAt {
            return
        }
        let data = try PlaybackProgress.encoder.encode(stats)
        try await source.writeFile(data, to: Self.statsPath)
    }

    func pullStats() async throws -> SmartSpeechStatsRecord? {
        guard let data = try? await source.readFile(at: Self.statsPath) else { return nil }
        return try? PlaybackProgress.decoder.decode(SmartSpeechStatsRecord.self, from: data)
    }

    func pushCollections(_ manifest: CollectionsManifest) async throws {
        let path = Self.collectionsPath(for: manifest.kind)
        if let data = try? await source.readFile(at: path),
           let existing = try? PlaybackProgress.decoder.decode(CollectionsManifest.self, from: data),
           existing.updatedAt > manifest.updatedAt {
            return
        }
        let data = try PlaybackProgress.encoder.encode(manifest)
        try await source.writeFile(data, to: path)
    }

    func pullCollections(kind: FolderKind) async throws -> CollectionsManifest? {
        guard let data = try? await source.readFile(at: Self.collectionsPath(for: kind)) else {
            return nil
        }
        return try? PlaybackProgress.decoder.decode(CollectionsManifest.self, from: data)
    }

    /// Same stable hash scheme as Dropbox so a path key always maps to one filename.
    static func path(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(folder)/\(hex).json"
    }
}
