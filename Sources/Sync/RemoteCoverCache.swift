import Foundation
import UIKit

/// Disk cache for catalogue cover art fetched *before* the book/audiobook is downloaded.
/// Paths are container-relative under `Covers/remote/` so they survive relaunches and
/// share the same Application Support root as imported covers.
enum RemoteCoverCache {
    private static let folder = "Covers/remote"
    /// Sentinel written when a fetch already failed so we don't hammer the NAS.
    /// Bump the suffix when the extractor gains new formats so old misses retry.
    private static let missSuffix = ".miss-v2"

    static func relativePath(forEntryId id: String) -> String {
        "\(folder)/\(stableKey(id)).jpg"
    }

    private static func missPath(forEntryId id: String) -> String {
        "\(folder)/\(stableKey(id))\(missSuffix)"
    }

    /// Returns the relative path if a JPEG is already on disk.
    static func existingPath(forEntryId id: String) -> String? {
        let rel = relativePath(forEntryId: id)
        guard let url = try? ContainerPaths.url(forRelativePath: rel),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return rel
    }

    static func hasFailed(forEntryId id: String) -> Bool {
        guard let url = try? ContainerPaths.url(forRelativePath: missPath(forEntryId: id)) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func markFailed(forEntryId id: String) {
        guard let url = try? ContainerPaths.url(forRelativePath: missPath(forEntryId: id)) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data().write(to: url)
    }

    /// Persist JPEG/PNG bytes (re-encoded as JPEG) and return the relative path.
    static func store(imageData: Data, forEntryId id: String) throws -> String? {
        guard let image = UIImage(data: imageData),
              let jpeg = image.jpegData(compressionQuality: 0.82) else { return nil }
        let rel = relativePath(forEntryId: id)
        let url = try ContainerPaths.url(forRelativePath: rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        // Clear any prior miss marker.
        if let miss = try? ContainerPaths.url(forRelativePath: missPath(forEntryId: id)) {
            try? FileManager.default.removeItem(at: miss)
        }
        return rel
    }

    private static func stableKey(_ id: String) -> String {
        // Filesystem-safe, stable across launches (not Swift Hasher — that is randomized).
        let data = Data(id.utf8)
        var hash: UInt64 = 5381
        for b in data {
            hash = ((hash << 5) &+ hash) &+ UInt64(b)
        }
        return String(format: "%016llx", hash)
    }
}
