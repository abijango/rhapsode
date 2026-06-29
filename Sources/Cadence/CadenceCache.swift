import Foundation
import SwiftData

// MARK: - In-use Registry

/// Thread-safe registry of trimmed-rendition relative paths currently loaded by a playing
/// `AudiobookPlayer`. Eviction consults this registry and never removes a file that is
/// in active use (spec §12: "never evict the rendition currently playing").
///
/// Uses `NSLock` so callers on both `@MainActor` (the player) and the `CadenceRenderCoordinator`
/// actor can access it synchronously without `await`.
final class CadenceInUseRegistry: @unchecked Sendable {
    static let shared = CadenceInUseRegistry()
    private let lock = NSLock()
    private var inUsePaths: Set<String> = []

    private init() {}

    func markInUse(_ relPath: String) {
        lock.withLock { inUsePaths.insert(relPath) }
    }

    func clearInUse(_ relPath: String) {
        lock.withLock { inUsePaths.remove(relPath) }
    }

    func isInUse(_ relPath: String) -> Bool {
        lock.withLock { inUsePaths.contains(relPath) }
    }
}

// MARK: - LRU Eviction

/// Cadence trimmed-rendition cache manager (spec §7, §12).
///
/// **Eviction policy:** when total bytes of on-disk trimmed `.m4a` files exceed `maxBytes`,
/// evict the least-recently-used renditions first until total falls below the cap, EXCEPT:
///   - renditions currently in use (playing) are never evicted.
///   - The `.m4a` file is deleted and `audioEvicted = true`, but the metadata row is RETAINED
///     so re-render only redoes the audio.
///
/// **Regenerate-on-demand:** `AudiobookPlayer.selectTrimmedSource` detects an evicted or missing
/// file and triggers `CadenceRenderCoordinator.shared.enqueue(bookID:)` before returning `nil`.
enum CadenceCache {
    /// Default cap: 2 GB of trimmed `.m4a` files in the Cadence cache.
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Evict LRU renditions until total on-disk bytes falls below `cap`.
    /// Call after a successful upsert, passing the coordinator's `ModelContext`.
    /// In-use renditions (tracked by `CadenceInUseRegistry`) are skipped.
    static func evictIfNeeded(context: ModelContext, cap: Int64 = CadenceCache.maxBytes) {
        // Fetch all rendition rows.
        guard let all = try? context.fetch(FetchDescriptor<TrimmedRendition>()) else { return }

        // Compute on-disk sizes for every non-evicted row that has a real file.
        struct Entry {
            let rendition: TrimmedRendition
            let url: URL
            let bytes: Int64
        }

        var entries: [Entry] = []
        for r in all {
            guard !r.audioEvicted,
                  let url = try? ContainerPaths.cacheURL(forRelativePath: r.trimmedRelPath),
                  FileManager.default.fileExists(atPath: url.path),
                  let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { continue }
            entries.append(Entry(rendition: r, url: url, bytes: size))
        }

        let total = entries.reduce(0) { $0 + $1.bytes }
        guard total > cap else { return }

        // Sort ascending by lastUsedAt so the oldest (LRU) comes first.
        let sorted = entries.sorted { $0.rendition.lastUsedAt < $1.rendition.lastUsedAt }

        var running = total
        for entry in sorted {
            guard running > cap else { break }
            // Never evict a rendition whose file is currently in use.
            if CadenceInUseRegistry.shared.isInUse(entry.rendition.trimmedRelPath) { continue }

            // Delete the .m4a; keep the metadata row with audioEvicted = true.
            try? FileManager.default.removeItem(at: entry.url)
            entry.rendition.audioEvicted = true
            running -= entry.bytes
        }
        try? context.save()
    }
}
