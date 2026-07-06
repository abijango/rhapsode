import Foundation

/// The single place where relative container paths become absolute URLs.
///
/// Design rules (from CLAUDE.md / SPEC.md):
///   • Media lives under **Application Support**, not Caches — Caches can be purged
///     by the system, and our downloaded books must persist.
///   • The media root is excluded from iCloud/iTunes backup so downloaded books
///     don't bloat the user's backup (they can always be re-downloaded).
///   • Models persist **relative** paths only; nothing else resolves rel→abs.
enum ContainerPaths {
    /// Subdirectory under Application Support that holds all downloaded media.
    private static let mediaDirName = "Media"

    /// Absolute URL of the media root, created (and backup-excluded) on first access.
    static func mediaRoot() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var root = appSupport.appendingPathComponent(mediaDirName, isDirectory: true)

        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try root.setResourceValues(values)
        }
        return root
    }

    /// Resolve a stored relative path to an absolute URL within the media root.
    static func url(forRelativePath relativePath: String) throws -> URL {
        try mediaRoot().appendingPathComponent(relativePath)
    }

    /// Convert an absolute URL back to a media-root-relative path for storage.
    /// Returns nil if `url` is not inside the media root.
    static func relativePath(for url: URL) throws -> String? {
        let root = try mediaRoot().standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full == root { return "" }
        // Match on a trailing separator so a sibling like "/MediaCache" is not
        // mistaken for being inside "/Media".
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard full.hasPrefix(rootPrefix) else { return nil }
        return String(full.dropFirst(rootPrefix.count))
    }
}
