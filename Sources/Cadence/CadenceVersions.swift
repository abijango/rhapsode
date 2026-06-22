import Foundation

/// Monotonic version stamps that pin a cached rendition to the logic that produced it.
///
/// A `TrimmedRendition` is valid only if its `analyzerVersion`/`rendererVersion` match these.
/// **Bump `analyzer`** when `SilenceAnalyzer` detection changes; **bump `renderer`** when
/// `OfflineTrimRenderer` or the AAC encode changes — either forces re-render + cache
/// invalidation for every book (spec §7.1 / §15). Keep these in lockstep with CadenceKit.
enum CadenceVersions {
    static let analyzer = 1
    static let renderer = 1
}

/// Cheap content fingerprint (size + mtime) used to detect that a source file changed under a
/// stable relative path — a fingerprint mismatch invalidates the cached rendition (spec §7.1).
/// Avoids hashing multi-hundred-MB audiobooks; sha256 can replace this later if needed.
enum CadenceFingerprint {
    /// `"<bytes>-<mtimeEpoch>"`, or `nil` if the file can't be stat'd.
    static func of(fileAt url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(Int64(mtime))"
    }
}
