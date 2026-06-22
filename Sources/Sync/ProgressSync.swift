import Foundation

/// Cross-device playback / reading progress for one library item, serialized to a
/// small JSON file in the Dropbox app folder so other devices can resume.
///
/// This is a **wire** model, not a SwiftData `@Model`: the local source of truth
/// stays in `Audiobook` / `Book`. The `key` is the stable container-relative
/// source path (`Audiobook.sourcePath` / `Book.fileRelPath`). Because every device
/// imports from the same Dropbox app folder through identical relative-path logic,
/// that key is byte-identical across devices — it is the cross-device join key.
struct PlaybackProgress: Codable, Sendable, Equatable {
    var key: String
    var kind: FolderKind
    var lastTrackIndex: Int
    var lastOffsetSeconds: Double
    var readingLocatorJSON: String?
    var updatedAt: Date

    /// Last-writer-wins decision: is `self` newer than a local change stamped at
    /// `localUpdatedAt`? A nil local stamp means "never synced locally" → the
    /// remote record always wins.
    func isNewer(than localUpdatedAt: Date?) -> Bool {
        guard let localUpdatedAt else { return true }
        return updatedAt > localUpdatedAt
    }

    /// Shared ISO-8601 coders so timestamps round-trip identically on every device
    /// (and on the future Android client).
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Transport-agnostic cross-device progress sync. The MVP conformer is
/// `DropboxProgressSync` (app-folder JSON files). The protocol keeps the mechanism
/// swappable and is the seam that ports to the planned Android client unchanged.
protocol ProgressSync: Sendable {
    /// Upload one item's progress. Conformers must avoid clobbering a strictly
    /// newer remote record (read-before-write LWW guard).
    func push(_ progress: PlaybackProgress) async throws
    /// Fetch every item's progress currently stored remotely.
    func pullAll() async throws -> [PlaybackProgress]
}

/// No-op sync for the mock / debug / background-refresh paths (needs no Dropbox
/// write scope). The default so existing `SyncManager` call sites stay unchanged.
struct NoopProgressSync: ProgressSync {
    func push(_ progress: PlaybackProgress) async throws {}
    func pullAll() async throws -> [PlaybackProgress] { [] }
}

/// In-memory `ProgressSync` for headless tests. Mirrors `DropboxProgressSync`'s
/// read-before-write LWW guard so the self-test exercises the real merge contract.
actor MockProgressSync: ProgressSync {
    private(set) var store: [String: PlaybackProgress] = [:]

    init(seed: [PlaybackProgress] = []) {
        for p in seed { store[p.key] = p }
    }

    func push(_ progress: PlaybackProgress) async throws {
        if let existing = store[progress.key], existing.updatedAt > progress.updatedAt { return }
        store[progress.key] = progress
    }

    func pullAll() async throws -> [PlaybackProgress] { Array(store.values) }
}
