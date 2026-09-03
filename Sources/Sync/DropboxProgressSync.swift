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
    var storesRemotely: Bool { true }
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

    /// Fixed path for the single shared SmartSpeech stats backup.
    static let statsPath = "\(folder)/cadence-stats.json"

    static func collectionsPath(for kind: FolderKind) -> String {
        switch kind {
        case .audiobooks: "\(folder)/collections-audiobooks.json"
        case .books: "\(folder)/collections-books.json"
        }
    }

    func pushStats(_ stats: SmartSpeechStatsRecord) async throws {
        // Same read-before-write LWW guard as `push`: don't clobber a strictly-newer remote.
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

    static func deviceStatsPath(deviceId: String) -> String {
        "\(folder)/devices/\(deviceId)/stats.json"
    }

    static func bookContributionPath(deviceId: String, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(folder)/devices/\(deviceId)/books/\(hex).json"
    }

    func pushDeviceStats(_ stats: DeviceStatsRecord) async throws {
        let path = Self.deviceStatsPath(deviceId: stats.deviceId)
        if let data = try? await source.readFile(at: path),
           let existing = try? PlaybackProgress.decoder.decode(DeviceStatsRecord.self, from: data),
           existing.updatedAt > stats.updatedAt {
            return
        }
        try await source.ensureFolderExists(Self.folder)
        try await source.ensureFolderExists("\(Self.folder)/devices")
        try await source.ensureFolderExists("\(Self.folder)/devices/\(stats.deviceId)")
        let data = try PlaybackProgress.encoder.encode(stats)
        try await source.writeFile(data, to: path)
    }

    func pullAllDeviceStats() async throws -> [DeviceStatsRecord] {
        let devices: [RemoteEntry]
        do {
            devices = try await source.listFolder("\(Self.folder)/devices")
        } catch {
            return []
        }
        var result: [DeviceStatsRecord] = []
        for entry in devices where entry.isFolder {
            if let data = try? await source.readFile(at: "\(entry.path)/stats.json"),
               let record = try? PlaybackProgress.decoder.decode(DeviceStatsRecord.self, from: data) {
                result.append(record)
            }
        }
        return result
    }

    func pushBookContribution(_ contribution: DeviceBookContribution) async throws {
        let path = Self.bookContributionPath(deviceId: contribution.deviceId, key: contribution.key)
        if let data = try? await source.readFile(at: path),
           let existing = try? PlaybackProgress.decoder.decode(DeviceBookContribution.self, from: data),
           existing.updatedAt > contribution.updatedAt {
            return
        }
        try await source.ensureFolderExists(Self.folder)
        try await source.ensureFolderExists("\(Self.folder)/devices")
        try await source.ensureFolderExists("\(Self.folder)/devices/\(contribution.deviceId)")
        try await source.ensureFolderExists("\(Self.folder)/devices/\(contribution.deviceId)/books")
        let data = try PlaybackProgress.encoder.encode(contribution)
        try await source.writeFile(data, to: path)
    }

    func pullAllBookContributions() async throws -> [DeviceBookContribution] {
        let devices: [RemoteEntry]
        do {
            devices = try await source.listFolder("\(Self.folder)/devices")
        } catch {
            return []
        }
        var result: [DeviceBookContribution] = []
        for device in devices where device.isFolder {
            let books: [RemoteEntry]
            do {
                books = try await source.listFolder("\(device.path)/books")
            } catch {
                continue
            }
            for entry in books where !entry.isFolder && entry.name.hasSuffix(".json") {
                if let data = try? await source.readFile(at: entry.path),
                   let c = try? PlaybackProgress.decoder.decode(DeviceBookContribution.self, from: data) {
                    result.append(c)
                }
            }
        }
        return result
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
        guard let data = try? await source.readFile(at: Self.collectionsPath(for: kind)) else { return nil }
        return try? PlaybackProgress.decoder.decode(CollectionsManifest.self, from: data)
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
