import CryptoKit
import Foundation

/// KOReader / Readest document fingerprint used as the KOSync `document` id.
///
/// Algorithm (matches Readest `utils/md5.ts` `partialMD5` and KOReader `util.partialMD5`):
/// sample 1024-byte windows at offsets produced by JS `1024 << (2 * i)` for `i = -1…10`,
/// then MD5 the concatenated samples. JS left-shift is 32-bit — critical for `i = -1`
/// where the shift yields `0`, not a huge offset.
enum PartialMD5 {
    private static let sampleSize = 1024
    private static let step = 1024

    /// Hex MD5 of the partial samples for the file at `url`.
    static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            return hexDigest(Data())
        }

        var hasher = Insecure.MD5()
        for i in -1...10 {
            let start = min(fileSize, Int64(jsShiftLeft(step, 2 * i)))
            if start >= fileSize { break }
            let end = min(start + Int64(sampleSize), fileSize)
            let length = Int(end - start)
            guard length > 0 else { continue }

            try handle.seek(toOffset: UInt64(start))
            let chunk: Data
            if #available(iOS 13.4, *) {
                chunk = try handle.read(upToCount: length) ?? Data()
            } else {
                chunk = handle.readData(ofLength: length)
            }
            if !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return hexDigest(hasher.finalize())
    }

    /// JS `ToInt32(value) << (ToUint32(shift) % 32)` as a non-negative offset.
    static func jsShiftLeft(_ value: Int, _ shift: Int) -> Int {
        let v = Int32(truncatingIfNeeded: value)
        let amount = Int(UInt32(bitPattern: Int32(truncatingIfNeeded: shift)) % 32)
        let shifted = v &<< amount
        // Match JS ToInt32 bit pattern interpreted as Number (can be 0 after overflow).
        return Int(shifted)
    }

    private static func hexDigest(_ digest: Insecure.MD5Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDigest(_ data: Data) -> String {
        hexDigest(Insecure.MD5.hash(data: data))
    }

    /// Full-buffer MD5 hex (password → `X-Auth-Key`).
    static func md5Hex(_ data: Data) -> String {
        hexDigest(data)
    }
}
