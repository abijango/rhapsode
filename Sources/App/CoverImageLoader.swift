import ImageIO
import UIKit

/// Async cover decode + downsample with an in-memory cache. Decoding runs off the main
/// actor; results are keyed by relative path and target pixel size.
enum CoverImageLoader {
    struct LoadedCover: Sendable {
        let image: UIImage
        /// Width ÷ height, clamped to shelf aspect bounds.
        let aspectRatio: CGFloat
    }

    /// Limits concurrent decodes so scrolling the shelf doesn't serialize on one actor.
    private actor DecodeGate {
        static let shared = DecodeGate()
        private let maxConcurrent = 4
        private var inFlight = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if inFlight < maxConcurrent {
                inFlight += 1
                return
            }
            await withCheckedContinuation { waiters.append($0) }
            inFlight += 1
        }

        func release() {
            inFlight -= 1
            if !waiters.isEmpty {
                waiters.removeFirst().resume()
            }
        }
    }

    actor Cache {
        static let shared = Cache()

        private final class Box: NSObject {
            let cover: LoadedCover
            init(_ cover: LoadedCover) { self.cover = cover }
        }

        private let cache = NSCache<NSString, Box>()
        private var inFlight: [String: Task<LoadedCover?, Never>] = [:]

        init() {
            cache.countLimit = 200
            cache.totalCostLimit = 96 * 1024 * 1024
        }

        func load(relativePath: String, maxPixelSize: CGFloat) async -> LoadedCover? {
            let key = "\(relativePath)|\(Int(maxPixelSize))"
            let nsKey = key as NSString
            if let hit = cache.object(forKey: nsKey) { return hit.cover }
            if let existing = inFlight[key] { return await existing.value }

            let task = Task<LoadedCover?, Never> {
                await DecodeGate.shared.acquire()
                defer { Task { await DecodeGate.shared.release() } }
                return await Self.decode(path: relativePath, maxPixelSize: maxPixelSize)
            }
            inFlight[key] = task
            defer { inFlight.removeValue(forKey: key) }
            guard let cover = await task.value else { return nil }
            let cost = Int(cover.image.size.width * cover.image.size.height
                * cover.image.scale * cover.image.scale * 4)
            cache.setObject(Box(cover), forKey: nsKey, cost: max(cost, 1))
            return cover
        }

        private static func decode(path: String, maxPixelSize: CGFloat) async -> LoadedCover? {
            await Task.detached(priority: .utility) {
                guard let url = try? ContainerPaths.url(forRelativePath: path) else { return nil }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    return nil
                }
                let image = UIImage(cgImage: cgImage)
                let w = image.size.width
                let h = image.size.height
                let raw = (w > 1 && h > 1) ? w / h : 1
                let aspect = min(max(raw, DS.Shelf.coverAspectMin), DS.Shelf.coverAspectMax)
                return LoadedCover(image: image, aspectRatio: aspect)
            }.value
        }
    }
}
