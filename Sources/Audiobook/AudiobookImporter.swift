import AVFoundation
import Foundation
import UIKit

/// Turns a downloaded local audiobook (an `.m4b` file or a folder of MP3s) into an
/// `Audiobook` + ordered `[AudiobookTrack]`. Stores only container-relative paths.
///
/// Format rules (SPEC.md):
///   • M4B → tracks come from `AVAsset` chapter metadata; every track shares the
///     one file. Chapter start = prefix sum of prior chapter durations (chapters
///     are contiguous), so no per-track offset needs storing.
///   • MP3 folder → each file is a track, ordered by ID3 track number, filename
///     as fallback. Cover from embedded artwork, else `cover.jpg` / `folder.jpg`.
struct AudiobookImporter {
    /// Build an `Audiobook` from a local URL already inside the container.
    /// The returned object is NOT yet inserted into a context.
    static func makeAudiobook(fromLocal localURL: URL) async throws -> Audiobook {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        return isDir.boolValue
            ? try await importMP3Folder(localURL)
            : try await importM4B(localURL)
    }

    // MARK: M4B

    private static func importM4B(_ url: URL) async throws -> Audiobook {
        let asset = AVURLAsset(url: url)
        let sourceRel = try relPath(url)
        let title = (try? await commonString(asset, .commonKeyTitle)) ?? url.deletingPathExtension().lastPathComponent
        let author = try? await commonString(asset, .commonKeyArtist)
        let coverPath = try await extractCover(asset: asset, folder: nil, baseName: title)

        let groups = try await chapterGroups(asset)
        var tracks: [AudiobookTrack] = []
        if groups.isEmpty {
            // No chapters: whole file is one track.
            let dur = try await asset.load(.duration).seconds
            tracks = [AudiobookTrack(title: title, fileRelPath: sourceRel, duration: dur, order: 0)]
        } else {
            for (i, group) in groups.enumerated() {
                let chapTitle = (try? await metadataString(group.items, .commonKeyTitle)) ?? "Chapter \(i + 1)"
                let dur = group.timeRange.duration.seconds
                tracks.append(AudiobookTrack(title: chapTitle, fileRelPath: sourceRel, duration: dur, order: i))
            }
        }
        let total = tracks.reduce(0) { $0 + $1.duration }
        let book = Audiobook(title: title, author: author, coverPath: coverPath,
                             sourcePath: sourceRel, tracks: tracks, totalDuration: total)
        return book
    }

    // MARK: MP3 folder

    private static func importMP3Folder(_ folder: URL) async throws -> Audiobook {
        let fm = FileManager.default
        let mp3s = (try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension.lowercased() == "mp3" }

        var parsed: [(url: URL, title: String, track: Int?, album: String?, artist: String?, dur: Double)] = []
        for file in mp3s {
            let asset = AVURLAsset(url: file)
            let title = (try? await commonString(asset, .commonKeyTitle)) ?? file.deletingPathExtension().lastPathComponent
            let album = try? await commonString(asset, .commonKeyAlbumName)
            let artist = try? await commonString(asset, .commonKeyArtist)
            let trackNo = try? await trackNumber(asset)
            let dur = (try? await asset.load(.duration).seconds) ?? 0
            parsed.append((file, title, trackNo, album, artist, dur))
        }
        // Order by ID3 track number; filename sort as fallback.
        parsed.sort { a, b in
            switch (a.track, b.track) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            }
        }

        var tracks: [AudiobookTrack] = []
        for (i, p) in parsed.enumerated() {
            tracks.append(AudiobookTrack(title: p.title, fileRelPath: try relPath(p.url), duration: p.dur, order: i))
        }

        let title = parsed.first?.album ?? folder.lastPathComponent
        let author = parsed.first?.artist
        // Cover: embedded in first track, else cover.jpg / folder.jpg in the directory.
        let cover = try await extractCover(asset: mp3s.first.map(AVURLAsset.init), folder: folder, baseName: title)

        let total = tracks.reduce(0) { $0 + $1.duration }
        let book = Audiobook(title: title, author: author, coverPath: cover,
                             sourcePath: try relPath(folder), tracks: tracks, totalDuration: total)
        return book
    }

    /// Load chapter groups robustly. `bestMatchingPreferredLanguages` can miss
    /// chapters that carry no language tag (common in transcoded M4Bs), so try the
    /// asset's own chapter locales first, then fall back.
    private static func chapterGroups(_ asset: AVURLAsset) async throws -> [AVTimedMetadataGroup] {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        for locale in locales {
            let groups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])
            if !groups.isEmpty { return groups }
        }
        let langs = locales.isEmpty ? Locale.preferredLanguages : locales.map(\.identifier)
        return (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: langs)) ?? []
    }

    // MARK: Metadata helpers

    private static func commonString(_ asset: AVAsset, _ key: AVMetadataKey) async throws -> String? {
        let items = try await asset.load(.commonMetadata)
        return try await metadataString(items, key)
    }

    private static func metadataString(_ items: [AVMetadataItem], _ key: AVMetadataKey) async throws -> String? {
        let matches = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common)
        guard let item = matches.first else { return nil }
        return try await item.load(.stringValue)
    }

    private static func trackNumber(_ asset: AVAsset) async throws -> Int? {
        let items = try await asset.load(.metadata)
        for id in [AVMetadataIdentifier.id3MetadataTrackNumber, .iTunesMetadataTrackNumber] {
            if let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id).first {
                if let n = try? await item.load(.numberValue)?.intValue { return n }
                if let s = try? await item.load(.stringValue) {
                    return Int(s.split(separator: "/").first.map(String.init) ?? s)
                }
            }
        }
        return nil
    }

    /// Save cover art into the container and return its relative path (or nil).
    private static func extractCover(asset: AVURLAsset?, folder: URL?, baseName: String) async throws -> String? {
        var imageData: Data?
        if let asset {
            let items = try await asset.load(.commonMetadata)
            if let art = AVMetadataItem.metadataItems(from: items, withKey: AVMetadataKey.commonKeyArtwork, keySpace: .common).first {
                imageData = try? await art.load(.dataValue)
            }
        }
        if imageData == nil, let folder {
            for name in ["cover.jpg", "folder.jpg", "cover.png"] {
                let candidate = folder.appendingPathComponent(name)
                if let d = try? Data(contentsOf: candidate) { imageData = d; break }
            }
        }
        guard let imageData, UIImage(data: imageData) != nil else { return nil }
        let rel = "Covers/\(UUID().uuidString).jpg"
        let dest = try ContainerPaths.url(forRelativePath: rel)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageData.write(to: dest)
        return rel
    }

    private static func relPath(_ url: URL) throws -> String {
        guard let rel = try ContainerPaths.relativePath(for: url) else {
            throw LibrarySourceError.notFound(path: url.path)
        }
        return rel
    }
}
