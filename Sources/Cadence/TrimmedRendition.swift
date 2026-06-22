import Foundation
import SwiftData

/// A cached, trimmed `.m4a` rendering of **one original source file** (spec §7.1).
///
/// Keying / invalidation: a rendition is valid for a request only if all four key fields —
/// `contentFingerprint`, `analyzerVersion`, `rendererVersion`, **and `tier`** — match. Any
/// mismatch ⇒ re-render. Identity (which file, which book) is `bookID` + `sourceFileRelPath`.
///
/// Per-file, not per-track: a single-file `.m4b` (all tracks share one `fileRelPath`) gets **one**
/// rendition; an MP3 folder gets one **per file** — so the existing per-file queue is untouched.
///
/// The trimmed audio lives in the Caches-backed Cadence cache (`ContainerPaths.cacheURL(...)`)
/// and is evictable; the lightweight metadata (maps, durations) survives audio eviction so a
/// re-render only redoes the audio (`audioEvicted`). Positions/chapters are source-domain; the
/// `timelineMapBlob`/`chapterMapBlob` carry the source↔trimmed mapping used only at playback.
@Model
final class TrimmedRendition {
    var bookID: UUID
    /// Relative path of the original source file this rendition trims (stable per-file identity;
    /// the spec's `fileRefHash`, kept as the readable relative path for debuggability).
    var sourceFileRelPath: String
    /// `CadenceSettings.Preset.rawValue` the audio was rendered for.
    var tier: String

    // MARK: Validity key (any mismatch ⇒ re-render)
    var contentFingerprint: String
    var analyzerVersion: Int
    var rendererVersion: Int

    /// Path of the trimmed `.m4a`, **relative to `ContainerPaths.cadenceCacheRoot()`**.
    /// Resolve with `ContainerPaths.cacheURL(forRelativePath:)`.
    var trimmedRelPath: String
    /// True when the audio file has been evicted but this metadata row is retained (spec §7.1).
    var audioEvicted: Bool

    var originalDuration: TimeInterval
    var trimmedDuration: TimeInterval
    var savedSeconds: TimeInterval

    /// Packed source↔trimmed timeline map (built crossfade-corrected in WP3).
    var timelineMapBlob: Data
    /// Packed chapter marks remapped to trimmed time (WP3).
    var chapterMapBlob: Data

    var createdAt: Date
    /// For LRU eviction (spec §7).
    var lastUsedAt: Date

    init(
        bookID: UUID,
        sourceFileRelPath: String,
        tier: String,
        contentFingerprint: String,
        analyzerVersion: Int,
        rendererVersion: Int,
        trimmedRelPath: String,
        audioEvicted: Bool = false,
        originalDuration: TimeInterval,
        trimmedDuration: TimeInterval,
        savedSeconds: TimeInterval,
        timelineMapBlob: Data,
        chapterMapBlob: Data,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.bookID = bookID
        self.sourceFileRelPath = sourceFileRelPath
        self.tier = tier
        self.contentFingerprint = contentFingerprint
        self.analyzerVersion = analyzerVersion
        self.rendererVersion = rendererVersion
        self.trimmedRelPath = trimmedRelPath
        self.audioEvicted = audioEvicted
        self.originalDuration = originalDuration
        self.trimmedDuration = trimmedDuration
        self.savedSeconds = savedSeconds
        self.timelineMapBlob = timelineMapBlob
        self.chapterMapBlob = chapterMapBlob
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Whether this rendition satisfies a request for the given key. Identity (`bookID`,
    /// `sourceFileRelPath`) is assumed already matched by the fetch.
    func isValid(forFingerprint fingerprint: String, tier: String) -> Bool {
        contentFingerprint == fingerprint
            && self.tier == tier
            && analyzerVersion == CadenceVersions.analyzer
            && rendererVersion == CadenceVersions.renderer
            && !audioEvicted
    }
}
