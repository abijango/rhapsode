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

    actor Cache {
        static let shared = Cache()

        private final class Box: NSObject {
            let cover: LoadedCover
            init(_ cover: LoadedCover) { self.cover = cover }
        }

        private let cache = NSCache<NSString, Box>()

        init() {
            cache.countLimit = 200
        }

        func load(relativePath: String, maxPixelSize: CGFloat) async -> LoadedCover? {
            let key = "\(relativePath)|\(Int(maxPixelSize))" as NSString
            if let hit = cache.object(forKey: key) { return hit.cover }
            guard let cover = await Self.decode(path: relativePath, maxPixelSize: maxPixelSize) else {
                return nil
            }
            cache.setObject(Box(cover), forKey: key)
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
