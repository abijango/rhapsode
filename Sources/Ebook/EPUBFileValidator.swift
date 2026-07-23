import Foundation

/// Shared pre-open checks for local EPUB files (empty / missing / not ZIP).
enum EPUBFileValidator {
    /// Returns a user-facing error string, or `nil` if the file looks openable.
    static func validateLocalEPUB(at url: URL) -> String? {
        let path = url.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else {
            return "Book file is empty or missing. Delete it and download again."
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            return "Book file is empty or missing. Delete it and download again."
        }
        // Tiny files can't be valid EPUBs (ZIP local file header alone is 30+ bytes).
        guard size >= 64 else {
            return "Book file is not a valid EPUB (too small). Delete and download again."
        }

        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return "Couldn’t read the book file. Delete it and download again."
        }
        defer { try? fh.close() }

        let magic = try? fh.read(upToCount: 4)
        // ZIP local file header (PK\x03\x04) or empty archive (PK\x05\x06).
        let zipLocal = Data([0x50, 0x4B, 0x03, 0x04])
        let zipEmpty = Data([0x50, 0x4B, 0x05, 0x06])
        if magic != zipLocal && magic != zipEmpty {
            return "Book file is not a valid EPUB (corrupt download). Delete and download again."
        }
        return nil
    }
}
