import Foundation
import UIKit

/// Pulls embedded cover art from MP4/M4B (`covr`) and MP3 (ID3 `APIC`) bytes
/// without needing AVFoundation or a complete local file.
///
/// All parsing is bounds-checked and fail-soft — corrupt or unusual atoms return
/// `nil` instead of trapping (Swift `Data` subscript is fatal on OOB).
enum EmbeddedCoverExtractor {

    // MARK: - MP4 / M4B (iTunes `covr` atom)

    /// Walk top-level atoms in `fileSize` using `read(offset:count:)` (SMB range reads).
    /// Skips huge `mdat` payloads; only downloads the `moov` box when found.
    static func coverFromMP4(
        fileSize: Int64,
        read: (Int64, Int) async throws -> Data
    ) async throws -> Data? {
        guard fileSize > 16 else { return nil }
        var offset: Int64 = 0
        var safety = 0
        while offset + 8 <= fileSize, safety < 64 {
            safety += 1
            let headerLen = min(16, Int(fileSize - offset))
            let header = try await read(offset, headerLen)
            guard let (atomSize, type) = parseAtomHeader(header, maxEnd: fileSize - offset) else {
                break
            }
            if type == "moov" {
                // moov is small vs audio; cap so a corrupt size can't pull gigabytes.
                guard atomSize > 8, atomSize < 64 * 1024 * 1024 else { return nil }
                let moov = try await read(offset, Int(atomSize))
                return coverFromMP4BoxTree(moov)
            }
            // Skip mdat / free / etc. by jumping the declared size (no download).
            offset += atomSize
            if atomSize <= 0 { break }
        }
        return nil
    }

    /// Search a moov (or any MP4 box tree) buffer for a `covr` → `data` image payload.
    static func coverFromMP4BoxTree(_ data: Data) -> Data? {
        // Re-base to a contiguous buffer with startIndex == 0 so all parsers can use 0-based offsets.
        let bytes = ContiguousBytes(data)
        var candidates: [Data] = []
        scanBoxes(bytes, depth: 0) { type, payload in
            guard type == "covr" else { return }
            if let img = parseIlstDataAtoms(payload) {
                candidates.append(img)
            }
        }
        // Prefer largest valid image (main cover, not a tiny thumbnail).
        return candidates
            .filter { UIImage(data: $0) != nil }
            .max(by: { $0.count < $1.count })
    }

    // MARK: - MP3 (ID3v2 APIC)

    /// Parse an ID3v2 tag from the start of an MP3. Pass the first ~1–2 MB.
    static func coverFromMP3Prefix(_ data: Data) -> Data? {
        let b = ContiguousBytes(data)
        guard b.count >= 10,
              b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 // "ID3"
        else { return nil }
        let ver = b[3]
        // size is synchsafe 28-bit
        let tagSize = Int(b[6] & 0x7F) << 21
            | Int(b[7] & 0x7F) << 14
            | Int(b[8] & 0x7F) << 7
            | Int(b[9] & 0x7F)
        guard tagSize >= 0, tagSize < 16 * 1024 * 1024 else { return nil }
        let hasExtended = (b[5] & 0x40) != 0
        var pos = 10
        if hasExtended, pos + 4 <= b.count {
            let extSize: Int
            if ver >= 4 {
                extSize = Int(b[pos] & 0x7F) << 21
                    | Int(b[pos + 1] & 0x7F) << 14
                    | Int(b[pos + 2] & 0x7F) << 7
                    | Int(b[pos + 3] & 0x7F)
            } else {
                extSize = b.u32BE(at: pos).map(Int.init) ?? 0
            }
            pos += 4 + max(0, min(extSize, b.count - pos) - 4)
            if pos < 0 || pos > b.count { return nil }
        }
        let end = min(b.count, 10 + tagSize)
        while pos >= 0, pos + 10 <= end {
            guard let frameID = b.fourCC(at: pos),
                  frameID.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }),
                  !frameID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  frameID != "\0\0\0\0"
            else { break }
            let frameSize: Int
            if ver >= 4 {
                frameSize = Int(b[pos + 4] & 0x7F) << 21
                    | Int(b[pos + 5] & 0x7F) << 14
                    | Int(b[pos + 6] & 0x7F) << 7
                    | Int(b[pos + 7] & 0x7F)
            } else {
                frameSize = b.u32BE(at: pos + 4).map(Int.init) ?? -1
            }
            let bodyStart = pos + 10
            guard frameSize >= 0,
                  bodyStart <= b.count,
                  bodyStart + frameSize <= b.count
            else { break }
            if frameID == "APIC" || frameID == "PIC" {
                if let img = parseAPIC(b.slice(bodyStart, frameSize), isV22: frameID == "PIC") {
                    return img
                }
            }
            pos = bodyStart + frameSize
        }
        return nil
    }

    // MARK: - Internals

    private static func parseAtomHeader(_ header: Data, maxEnd: Int64) -> (size: Int64, type: String)? {
        let b = ContiguousBytes(header)
        guard b.count >= 8 else { return nil }
        var size = Int64(b.u32BE(at: 0) ?? 0)
        let type = b.fourCC(at: 4) ?? ""
        if size == 1 {
            // 64-bit extended size
            guard b.count >= 16, let large = b.u64BE(at: 8) else { return nil }
            size = Int64(bitPattern: large)
        } else if size == 0 {
            // Extends to EOF
            size = maxEnd
        }
        guard size >= 8, size <= maxEnd else { return nil }
        return (size, type)
    }

    /// Recursively visit boxes. Only descend into metadata containers — never into
    /// `trak`/`stbl` sample tables (huge, and false-positive fourccs can appear there).
    private static func scanBoxes(_ data: ContiguousBytes, depth: Int, visit: (String, ContiguousBytes) -> Void) {
        guard depth < 12 else { return }
        var offset = 0
        var steps = 0
        while offset + 8 <= data.count, steps < 10_000 {
            steps += 1
            guard let size32 = data.u32BE(at: offset),
                  let type = data.fourCC(at: offset + 4)
            else { break }

            var headerLen = 8
            var atomSize = Int(size32)
            if size32 == 1 {
                guard offset + 16 <= data.count, let large = data.u64BE(at: offset + 8) else { break }
                // Cap absurd sizes.
                guard large <= UInt64(data.count - offset) else { break }
                atomSize = Int(large)
                headerLen = 16
            } else if size32 == 0 {
                atomSize = data.count - offset
            }
            guard atomSize >= headerLen,
                  atomSize <= data.count,
                  offset <= data.count - atomSize
            else { break }

            let payloadLen = atomSize - headerLen
            let payload = data.slice(offset + headerLen, payloadLen)
            visit(type, payload)

            // Only metadata path for covers — skip sample tables entirely.
            if type == "moov" || type == "udta" || type == "meta" || type == "ilst" {
                var nested = payload
                // `meta` has a 4-byte version/flags prefix before child boxes
                if type == "meta", nested.count >= 4 {
                    nested = nested.slice(4, nested.count - 4)
                }
                scanBoxes(nested, depth: depth + 1, visit: visit)
            }
            offset += atomSize
        }
    }

    /// iTunes ilst data atoms inside `covr`: version/flags + locale + image bytes.
    private static func parseIlstDataAtoms(_ covrPayload: ContiguousBytes) -> Data? {
        var offset = 0
        var best: Data?
        var steps = 0
        while offset + 8 <= covrPayload.count, steps < 64 {
            steps += 1
            guard let sizeU = covrPayload.u32BE(at: offset),
                  let type = covrPayload.fourCC(at: offset + 4)
            else { break }
            let size = Int(sizeU)
            // Reject nonsense sizes (including 0 / overflow).
            guard size >= 8,
                  size <= covrPayload.count,
                  offset <= covrPayload.count - size
            else { break }

            if type == "data", size >= 16 {
                // [version:1][flags:3][locale:4][image…]
                let imageLen = size - 16
                if imageLen > 0, let image = covrPayload.dataSlice(offset + 16, imageLen),
                   UIImage(data: image) != nil {
                    if best == nil || image.count > best!.count {
                        best = image
                    }
                }
            }
            offset += size
            if size == 0 { break }
        }
        // Some files store raw JPEG/PNG with only a short header.
        if best == nil, covrPayload.count > 24 {
            for skip in [0, 8, 16] where skip < covrPayload.count {
                if let raw = covrPayload.dataSlice(skip, covrPayload.count - skip),
                   UIImage(data: raw) != nil {
                    best = raw
                    break
                }
            }
        }
        return best
    }

    private static func parseAPIC(_ frame: ContiguousBytes, isV22: Bool) -> Data? {
        guard frame.count > 4 else { return nil }
        var i = 0
        let encoding = frame[i]; i += 1
        if isV22 {
            guard i + 3 <= frame.count else { return nil }
            i += 3 // Image format 3 chars e.g. "JPG"
        } else {
            // MIME type, null-terminated
            while i < frame.count, frame[i] != 0 { i += 1 }
            guard i < frame.count else { return nil }
            i += 1 // skip NUL
        }
        guard i < frame.count else { return nil }
        i += 1 // picture type
        guard i <= frame.count else { return nil }
        // Description (encoding-dependent terminator)
        if encoding == 0 || encoding == 3 {
            while i < frame.count, frame[i] != 0 { i += 1 }
            if i < frame.count { i += 1 }
        } else {
            while i + 1 < frame.count, !(frame[i] == 0 && frame[i + 1] == 0) { i += 2 }
            if i + 1 < frame.count { i += 2 }
        }
        guard i < frame.count else { return nil }
        let image = frame.dataSlice(i, frame.count - i)
        guard let image, UIImage(data: image) != nil else { return nil }
        return image
    }
}

// MARK: - Safe byte buffer (always 0-based, never traps)

/// Contiguous copy of `Data` with 0-based indexing and optional accessors.
private struct ContiguousBytes {
    private let storage: [UInt8]

    var count: Int { storage.count }

    init(_ data: Data) {
        // Always copy so startIndex is 0 and we never share a sliced Data view.
        self.storage = [UInt8](data)
    }

    private init(storage: [UInt8]) {
        self.storage = storage
    }

    subscript(_ i: Int) -> UInt8 {
        // Fail-soft: callers should bounds-check first; return 0 rather than trap.
        guard i >= 0, i < storage.count else { return 0 }
        return storage[i]
    }

    func u32BE(at i: Int) -> UInt32? {
        guard i >= 0, i + 4 <= storage.count else { return nil }
        return (UInt32(storage[i]) << 24)
            | (UInt32(storage[i + 1]) << 16)
            | (UInt32(storage[i + 2]) << 8)
            | UInt32(storage[i + 3])
    }

    func u64BE(at i: Int) -> UInt64? {
        guard i >= 0, i + 8 <= storage.count else { return nil }
        var v: UInt64 = 0
        for b in 0..<8 { v = (v << 8) | UInt64(storage[i + b]) }
        return v
    }

    func fourCC(at i: Int) -> String? {
        guard i >= 0, i + 4 <= storage.count else { return nil }
        let bytes = storage[i..<(i + 4)]
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    func slice(_ start: Int, _ length: Int) -> ContiguousBytes {
        guard start >= 0, length >= 0, start <= storage.count, start + length <= storage.count else {
            return ContiguousBytes(storage: [])
        }
        return ContiguousBytes(storage: Array(storage[start..<(start + length)]))
    }

    func dataSlice(_ start: Int, _ length: Int) -> Data? {
        guard start >= 0, length >= 0, start <= storage.count, start + length <= storage.count else {
            return nil
        }
        return Data(storage[start..<(start + length)])
    }
}
