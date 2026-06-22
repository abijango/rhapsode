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
        progressUpdatedAt: Date? = nil
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
    }

    /// Tracks in playback order. Always sort by `order` — never rely on the
    /// stored relationship array order.
    var orderedTracks: [AudiobookTrack] {
        tracks.sorted { $0.order < $1.order }
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
    /// Readium `Locator` serialized as JSON; nil until first opened.
    var readingLocator: String?
    /// When the reading position was last changed locally (or applied from a remote
    /// sync). Drives last-writer-wins for cross-device progress sync (Phase 5).
    var progressUpdatedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        author: String? = nil,
        coverPath: String? = nil,
        fileRelPath: String,
        readingLocator: String? = nil,
        progressUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.fileRelPath = fileRelPath
        self.readingLocator = readingLocator
        self.progressUpdatedAt = progressUpdatedAt
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

    init(
        id: UUID = UUID(),
        remoteEntryID: String,
        title: String? = nil,
        kind: FolderKind,
        state: DownloadState = .pending,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = 0
    ) {
        self.id = id
        self.remoteEntryID = remoteEntryID
        self.title = title
        self.kind = kind
        self.state = state
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
    }
}

// MARK: - Schema

/// Single source of truth for the model set. Used to build the `ModelContainer`.
enum AppSchema {
    static let models: [any PersistentModel.Type] = [
        Audiobook.self,
        AudiobookTrack.self,
        Book.self,
        WatchedFolder.self,
        DownloadItem.self,
    ]
}
