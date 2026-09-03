import Foundation
import SwiftData

// MARK: - Shared enums

/// Which watched root a folder / download belongs to.
enum FolderKind: String, Codable, Sendable {
    case audiobooks
    case books
}

/// Lifecycle of a single download in the queue.
enum DownloadState: String, Codable, Sendable {
    case pending
    case downloading
    case done
    case failed
}

// MARK: - Models
//
// Persistence rules (from CLAUDE.md / SPEC.md), enforced by convention here:
//   • Store **relative** container paths only — never an absolute URL. They are
//     resolved to absolute URLs at use time via `ContainerPaths`.
//   • Use stable `UUID`s so a future CloudKit sync is a toggle, not a rewrite.
//     Deliberately NO `@Attribute(.unique)`: SwiftData-over-CloudKit rejects unique
//     constraints, and `UUID()` defaults already guarantee uniqueness.
//   • Ordered tracks are ordered by the explicit `order` field, NOT by SwiftData
//     relationship order (SwiftData relationships are unordered).

@Model
final class Audiobook {
    var id: UUID
    var title: String
    var author: String?
    /// Relative path to cover art within the media container, if any.
    var coverPath: String?
    /// Relative path to the source file (M4B) or MP3 folder within the container.
    var sourcePath: String
    @Relationship(deleteRule: .cascade, inverse: \AudiobookTrack.audiobook)
    var tracks: [AudiobookTrack]
    /// Resume position: index into the `order`-sorted tracks.
    var lastTrackIndex: Int
    /// Resume position: offset within the current track.
    var lastOffsetSeconds: Double
    var totalDuration: Double
    /// When this book's progress was last changed locally (or applied from a remote
    /// sync). Drives last-writer-wins for cross-device progress sync (Phase 5).
    /// Optional with a nil default — additive, CloudKit-safe lightweight migration.
    var progressUpdatedAt: Date?
    /// Shelf progress cache (0...1). Updated when position is persisted or merged
    /// from sync so tile bodies never sort `orderedTracks` on the hot path.
    /// Nil on older rows until the next save — `shelfFractionComplete` falls back once.
    var cachedFractionComplete: Double?
    /// SmartSpeech (silence-trimming) per-book tier override, as `SmartSpeechSettings.Preset.rawValue`
    /// ("default"/"more"/"aggressive"). `nil` → inherit the global default tier. Resolve via
    /// `effectiveSmartSpeechTier`. Additive optional → lightweight, CloudKit-safe migration.
    /// `originalName` keeps the stored column as `cadenceTier` (its name before the SmartSpeech
    /// rename) so existing per-book settings migrate in place instead of resetting.
    @Attribute(originalName: "cadenceTier") var smartSpeechTier: String?
    /// Set to `true` when the audio is undecodable (e.g. DRM-protected) — SmartSpeech rendering and
    /// selection are skipped permanently for this book. Additive optional (default nil treated as
    /// false) → lightweight, CloudKit-safe migration. Mirror of `smartSpeechTier` pattern.
    @Attribute(originalName: "cadenceUnavailable") var smartSpeechUnavailable: Bool?
    /// Cumulative seconds of silence SmartSpeech has trimmed away **for this book**, accrued as the
    /// user actually listens through trimmed audio. Drives the per-book stat and the global
    /// "across N audiobooks" count. Additive optional (nil treated as 0) → lightweight migration.
    @Attribute(originalName: "cadenceSavedSeconds") var smartSpeechSavedSeconds: Double?
    /// Cumulative seconds of trimmed/output CONTENT actually listened through **for this book**
    /// (rate-independent — the per-tick trimmed-domain delta, accrued whether or not SmartSpeech is
    /// trimming). Drives the per-book "played" stat. Additive optional (nil treated as 0) →
    /// lightweight, CloudKit-safe migration.
    var listenedSeconds: Double?
    /// User-defined collections (tags) for filtering the shelf. Per-shelf scope via `LibraryCollection.kind`.
    @Relationship(deleteRule: .nullify)
    var collections: [LibraryCollection]

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        coverPath: String? = nil,
        sourcePath: String,
        tracks: [AudiobookTrack] = [],
        lastTrackIndex: Int = 0,
        lastOffsetSeconds: Double = 0,
        totalDuration: Double = 0,
        progressUpdatedAt: Date? = nil,
        cachedFractionComplete: Double? = nil,
        smartSpeechTier: String? = nil,
        smartSpeechUnavailable: Bool? = nil,
        smartSpeechSavedSeconds: Double? = nil,
        listenedSeconds: Double? = nil,
        collections: [LibraryCollection] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.sourcePath = sourcePath
        self.tracks = tracks
        self.lastTrackIndex = lastTrackIndex
        self.lastOffsetSeconds = lastOffsetSeconds
        self.totalDuration = totalDuration
        self.progressUpdatedAt = progressUpdatedAt
        self.cachedFractionComplete = cachedFractionComplete
        self.smartSpeechTier = smartSpeechTier
        self.smartSpeechUnavailable = smartSpeechUnavailable
        self.smartSpeechSavedSeconds = smartSpeechSavedSeconds
        self.listenedSeconds = listenedSeconds
        self.collections = collections
    }

    /// Tracks in playback order. Always sort by `order` — never rely on the
    /// stored relationship array order.
    var orderedTracks: [AudiobookTrack] {
        tracks.sorted { $0.order < $1.order }
    }

    /// Source-domain seconds played so far, derived from the persisted resume
    /// position. Consistent across formats: the cumulative duration of completed
    /// segments plus the offset into the current one.
    var playedSeconds: Double {
        let ordered = orderedTracks
        guard !ordered.isEmpty else { return 0 }
        let idx = min(max(lastTrackIndex, 0), ordered.count - 1)
        let prior = ordered.prefix(idx).reduce(0) { $0 + $1.duration }
        return prior + max(0, lastOffsetSeconds)
    }

    /// Fraction of the whole book completed (0...1), for the shelf progress bar.
    /// Falls back to summed track durations when `totalDuration` is unset so the
    /// bar is never blank for an older/partially-imported book.
    var fractionComplete: Double {
        let total = totalDuration > 0 ? totalDuration : orderedTracks.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return 0 }
        return min(1, max(0, playedSeconds / total))
    }

    /// Shelf hot path — prefer the persisted cache; recompute once when missing.
    var shelfFractionComplete: Double {
        if let cachedFractionComplete { return cachedFractionComplete }
        return fractionComplete
    }

    /// Recompute and store shelf fraction after a position write or remote merge.
    func refreshCachedFractionComplete() {
        cachedFractionComplete = fractionComplete
    }
}

@Model
final class AudiobookTrack {
    var id: UUID
    var title: String
    /// Relative path within the container. For M4B all tracks share one file.
    var fileRelPath: String
    var duration: Double
    /// Explicit ordering key (ID3 track number / chapter index).
    var order: Int
    var audiobook: Audiobook?

    init(
        id: UUID = UUID(),
        title: String,
        fileRelPath: String,
        duration: Double,
        order: Int,
        audiobook: Audiobook? = nil
    ) {
        self.id = id
        self.title = title
        self.fileRelPath = fileRelPath
        self.duration = duration
        self.order = order
        self.audiobook = audiobook
    }
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String?
    var coverPath: String?
    /// Relative path to the EPUB within the container.
    var fileRelPath: String
    /// Reading position JSON; nil until first opened.
    /// Foliate: `{ "engine":"foliate", "cfi":"…", "locations":{ "totalProgression": 0.42 } }`.
    /// Legacy Readium: full Locator JSON (resume uses totalProgression only under Foliate).
    var readingLocator: String?
    /// When the reading position was last changed locally (or applied from a remote
    /// sync). Drives last-writer-wins for cross-device progress sync (Phase 5).
    var progressUpdatedAt: Date?
    /// Cumulative seconds spent reading with this book open in the foreground.
    /// Additive optional (nil treated as 0) → lightweight, CloudKit-safe migration.
    var readingSeconds: Double?
    /// Set when `fractionComplete` crosses ~98%. Additive optional → lightweight migration.
    var finishedAt: Date?
    /// KOReader partial-MD5 document id (cached). Additive optional → lightweight migration.
    var koreaderDocumentHash: String?
    /// User-defined collections (tags) for filtering the shelf. Per-shelf scope via `LibraryCollection.kind`.
    @Relationship(deleteRule: .nullify)
    var collections: [LibraryCollection]

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        coverPath: String? = nil,
        fileRelPath: String,
        readingLocator: String? = nil,
        progressUpdatedAt: Date? = nil,
        readingSeconds: Double? = nil,
        finishedAt: Date? = nil,
        koreaderDocumentHash: String? = nil,
        collections: [LibraryCollection] = []
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.fileRelPath = fileRelPath
        self.readingLocator = readingLocator
        self.progressUpdatedAt = progressUpdatedAt
        self.readingSeconds = readingSeconds
        self.finishedAt = finishedAt
        self.koreaderDocumentHash = koreaderDocumentHash
        self.collections = collections
    }

    /// Overall reading progress (0...1) for the shelf, from
    /// `locations.totalProgression` in the Foliate (or legacy) progress JSON.
    /// 0 when never opened or the field is missing.
    var fractionComplete: Double {
        guard let json = readingLocator,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locations = obj["locations"] as? [String: Any],
              let total = locations["totalProgression"] as? Double else { return 0 }
        return min(1, max(0, total))
    }
}

/// A user-defined collection (tag) for grouping shelf items. Scoped per shelf via `kind` —
/// audiobook collections never mix with e-book collections.
@Model
final class LibraryCollection {
    var id: UUID
    var name: String
    var kind: FolderKind
    var createdAt: Date
    @Relationship(inverse: \Audiobook.collections)
    var audiobooks: [Audiobook]
    @Relationship(inverse: \Book.collections)
    var books: [Book]

    init(
        id: UUID = UUID(),
        name: String,
        kind: FolderKind,
        createdAt: Date = Date(),
        audiobooks: [Audiobook] = [],
        books: [Book] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.audiobooks = audiobooks
        self.books = books
    }
}

@Model
final class WatchedFolder {
    var id: UUID
    var kind: FolderKind
    /// Remote path relative to the Dropbox app folder (e.g. "/Audiobooks").
    var remotePath: String
    /// Delta cursor from `list_folder`, persisted to resume change detection.
    var cursor: String?

    init(
        id: UUID = UUID(),
        kind: FolderKind,
        remotePath: String,
        cursor: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.remotePath = remotePath
        self.cursor = cursor
    }
}

@Model
final class DownloadItem {
    var id: UUID
    /// Identifier of the `RemoteEntry` this download corresponds to.
    var remoteEntryID: String
    /// Human-readable file name for display (optional for migration safety).
    var title: String?
    var kind: FolderKind
    var state: DownloadState
    var bytesReceived: Int64
    var totalBytes: Int64
    /// Shared by every child transfer when downloading an MP3-folder audiobook (Phase 3b).
    /// `nil` for single-file downloads. Additive optional → lightweight migration.
    var groupID: String?
    /// Container-relative folder path to import once every child in `groupID` reaches `.done`
    /// (e.g. `Audiobooks/MyBook`). Set on each group member; `nil` for single-file items.
    var groupFolderRelPath: String?
    /// Dropbox path used to build `downloadRequest` (e.g. `/Audiobooks/MyBook/track01.mp3`).
    /// Stored for retry after a failed background transfer. Additive optional → lightweight migration.
    var remotePath: String?

    init(
        id: UUID = UUID(),
        remoteEntryID: String,
        title: String? = nil,
        kind: FolderKind,
        state: DownloadState = .pending,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0,
        groupID: String? = nil,
        groupFolderRelPath: String? = nil,
        remotePath: String? = nil
    ) {
        self.id = id
        self.remoteEntryID = remoteEntryID
        self.title = title
        self.kind = kind
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.groupID = groupID
        self.groupFolderRelPath = groupFolderRelPath
        self.remotePath = remotePath
    }
}

// MARK: - Schema

/// Single source of truth for the model set. Used to build the `ModelContainer`.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Audiobook.self,
        AudiobookTrack.self,
        Book.self,
        LibraryCollection.self,
        WatchedFolder.self,
        DownloadItem.self,
    ]
}
