#if DEBUG
import Foundation
@preconcurrency import ReadiumShared
import SwiftData

/// Phase 0 verification harness. Runs only when the app is launched with the
/// `-phase0selftest` argument (so it never runs in normal use). Exercises the two
/// paths that UI rendering alone does not prove: the LibraryStore save path and
/// the ContainerPaths relative↔absolute round-trip.
///
/// Run it:
///   xcrun simctl launch --console <device> com.naufalmir.rhapsode -phase0selftest 1
@MainActor
enum PhaseZeroSelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("-phase0selftest")
    }

    static let tag = "PHASE0SELFTEST"

    static func run(context: ModelContext) async {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        // 1. ContainerPaths round-trip + sibling-prefix safety.
        do {
            let rel = "Audiobooks/sample.m4b"
            let abs = try ContainerPaths.url(forRelativePath: rel)
            let back = try ContainerPaths.relativePath(for: abs)
            check("ContainerPaths rel→abs→rel round-trips", back == rel)

            let root = try ContainerPaths.mediaRoot()
            let sibling = root.deletingLastPathComponent()
                .appendingPathComponent("MediaCache/x.txt")
            let outside = try ContainerPaths.relativePath(for: sibling)
            check("ContainerPaths rejects sibling (/MediaCache)", outside == nil)
        } catch {
            check("ContainerPaths threw: \(error)", false)
        }

        // 2. LibraryStore insert → save → fetch → delete.
        do {
            let store = LibraryStore(context: context)
            let marker = "selftest-\(UUID().uuidString)"
            let book = Audiobook(title: marker, sourcePath: marker)
            store.insert(book)
            try store.save()

            let fetched = try store.audiobooks().filter { $0.title == marker }
            check("LibraryStore insert→save→fetch finds the row", fetched.count == 1)

            fetched.forEach { store.delete($0) }
            try store.save()
            let afterDelete = try store.audiobooks().filter { $0.title == marker }
            check("LibraryStore delete→save removes the row", afterDelete.isEmpty)
        } catch {
            check("LibraryStore threw: \(error)", false)
        }

        // 3. MockLibrarySource serves bundled fixtures and downloads them.
        do {
            let mock = MockLibrarySource()
            let audiobooks = try await mock.listFolder("/Audiobooks")
            let books = try await mock.listFolder("/Books")
            check("Mock lists ≥2 audiobook fixtures", audiobooks.count >= 2)
            check("Mock lists ≥1 book fixture", books.count >= 1)

            if let epub = books.first {
                let dest = try ContainerPaths.url(forRelativePath: "selftest/\(epub.name)")
                try await mock.download(epub, to: dest)
                let exists = FileManager.default.fileExists(atPath: dest.path)
                check("Mock downloads EPUB into container", exists)
                try? FileManager.default.removeItem(
                    at: dest.deletingLastPathComponent())
            } else {
                check("Mock had a book fixture to download", false)
            }
        } catch {
            check("MockLibrarySource threw: \(error)", false)
        }

        // 4. Dropbox source wiring (no network).
        do {
            check("DropboxConfig has an app key", DropboxConfig.isConfigured)

            let kc = KeychainTokenStore(service: "selftest.rhapsode.dropbox", account: "t")
            try? kc.clear()
            let sample = DropboxTokens(
                refreshToken: "r", accessToken: "a",
                accessTokenExpiry: Date(timeIntervalSince1970: 0))
            try kc.save(sample)
            let loaded = try kc.load()
            check("Keychain save→load round-trips", loaded?.refreshToken == "r")
            try kc.clear()
            check("Keychain clear removes token", (try kc.load()) == nil)

            let dbx = DropboxSource(keychain: kc)
            do {
                try await dbx.authenticate()
                check("DropboxSource.authenticate throws without token", false)
            } catch LibrarySourceError.notAuthenticated {
                check("DropboxSource.authenticate throws without token", true)
            }
        } catch {
            check("Dropbox wiring threw: \(error)", false)
        }

        // 5. Audiobook import (M4B chapters + MP3 folder ordering) + resume round-trip.
        do {
            let mock = MockLibrarySource()
            let entries = try await mock.listFolder("/Audiobooks")

            var m4b: Audiobook?
            var folder: Audiobook?
            for entry in entries {
                let dest = try ContainerPaths.url(forRelativePath: "selftest-ab/\(entry.name)")
                try await mock.download(entry, to: dest)
                let book = try await AudiobookImporter.makeAudiobook(fromLocal: dest)
                if entry.name.hasSuffix(".m4b") { m4b = book } else { folder = book }
            }

            check("M4B parses 2 chapters", m4b?.tracks.count == 2)
            check("M4B chapters share one file (single-file)",
                  Set((m4b?.tracks ?? []).map(\.fileRelPath)).count == 1)
            check("MP3 folder parses 2 tracks", folder?.tracks.count == 2)
            check("MP3 tracks have distinct files",
                  Set((folder?.tracks ?? []).map(\.fileRelPath)).count == 2)
            check("MP3 tracks ordered 0,1",
                  (folder?.orderedTracks ?? []).map(\.order) == [0, 1])

            // Resume round-trip on the multi-file (MP3) book: jump to track 2,
            // persist, reload, expect restore.
            if let folder {
                context.insert(folder)
                try? context.save()
                let p1 = AudiobookPlayer()
                p1.load(folder, context: context)
                // Actually play briefly so the periodic time observer fires — this
                // exercises the AVFoundation→main-actor hop that previously crashed.
                p1.play()
                try? await Task.sleep(for: .seconds(1.2))
                check("Playback advances without crashing", p1.isPlaying)
                p1.pause()
                p1.jump(toTrack: 1)
                p1.seekInTrack(to: 1.5)
                p1.teardown()
                let p2 = AudiobookPlayer()
                p2.load(folder, context: context)
                check("Audiobook resume restores last track index", p2.currentIndex == 1)
                check("Audiobook resume restores offset", abs(p2.offsetInTrack - 1.5) < 0.5)
                p2.teardown()
                context.delete(folder)
                try? context.save()
            }
            try? FileManager.default.removeItem(
                at: try ContainerPaths.url(forRelativePath: "selftest-ab"))
        } catch {
            check("Audiobook import threw: \(error)", false)
        }

        // 6. E-book import + Readium reader pipeline + Locator JSON round-trip.
        do {
            let mock = MockLibrarySource()
            if let epub = try await mock.listFolder("/Books").first {
                let dest = try ContainerPaths.url(forRelativePath: "selftest-bk/\(epub.name)")
                try await mock.download(epub, to: dest)
                let book = try await EbookImporter.makeBook(fromLocal: dest)
                check("EPUB title parsed", book.title == "Sample Book")
                check("EPUB author parsed", book.author == "Sample Author")

                context.insert(book)
                try? context.save()
                let reader = EbookReader()
                await reader.open(book, context: context)
                check("Reader builds navigator", reader.navigator != nil)
                check("Reader reports no load error", reader.loadError == nil)
                check("Reader TOC has 2 entries", reader.toc.count == 2)
                context.delete(book)
                try? context.save()

                try? FileManager.default.removeItem(
                    at: try ContainerPaths.url(forRelativePath: "selftest-bk"))
            } else {
                check("Had an EPUB fixture", false)
            }

            // Locator persistence round-trip (serialize → parse → serialize).
            let original = Locator(href: URL(string: "OEBPS/ch1.xhtml")!, mediaType: .xhtml, title: "Chapter One")
            let json = try original.jsonString()
            let parsed = try Locator(json: try JSONValue(jsonString: json, warnings: nil), warnings: nil)
            check("Locator JSON round-trips", (try? parsed?.jsonString()) == json)
        } catch {
            check("E-book pipeline threw: \(error)", false)
        }

        // 7. Watched-folder bootstrap (via mock): seeds 2 folders, idempotent.
        do {
            let existing = try context.fetch(FetchDescriptor<WatchedFolder>())
            existing.forEach { context.delete($0) }
            try? context.save()

            let sync = SyncManager(source: MockLibrarySource(), context: context)
            try await sync.bootstrap()
            let seeded = try context.fetch(FetchDescriptor<WatchedFolder>())
            check("Bootstrap seeds 2 watched folders", seeded.count == 2)
            check("Watched folders have cursors", seeded.allSatisfy { $0.cursor != nil })

            try await sync.bootstrap()
            check("Bootstrap is idempotent", try context.fetch(FetchDescriptor<WatchedFolder>()).count == 2)

            try context.fetch(FetchDescriptor<WatchedFolder>()).forEach { context.delete($0) }
            try? context.save()
        } catch {
            check("Bootstrap threw: \(error)", false)
        }

        // 8. Sync pipeline via mock: scanNow downloads+imports, creates DownloadItems, dedups.
        do {
            // Clean slate.
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            for b in try context.fetch(FetchDescriptor<Book>()) { context.delete(b) }
            for d in try context.fetch(FetchDescriptor<DownloadItem>()) { context.delete(d) }
            try? context.save()

            let sync = SyncManager(source: MockLibrarySource(), context: context)
            await sync.scanNow()
            let downloads = try context.fetch(FetchDescriptor<DownloadItem>())
            check("Scan creates download items", downloads.count >= 3)
            check("All downloads marked done", downloads.allSatisfy { $0.state == .done })
            check("Downloads have human-readable titles", downloads.allSatisfy { !($0.title ?? "").isEmpty })
            check("Scan imported audiobooks", try context.fetch(FetchDescriptor<Audiobook>()).count >= 2)
            check("Scan imported a book", try context.fetch(FetchDescriptor<Book>()).count >= 1)

            await sync.scanNow()
            check("Scan dedups (no duplicate downloads)",
                  try context.fetch(FetchDescriptor<DownloadItem>()).count == downloads.count)

            // Delete removes the model and its local file.
            let store = LibraryStore(context: context)
            if let victim = try context.fetch(FetchDescriptor<Book>()).first {
                let fileURL = try ContainerPaths.url(forRelativePath: victim.fileRelPath)
                store.deleteBook(victim)
                check("Delete removes the local file", !FileManager.default.fileExists(atPath: fileURL.path))
                check("Delete removes the book row", try context.fetch(FetchDescriptor<Book>()).isEmpty)
            }

            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            for b in try context.fetch(FetchDescriptor<Book>()) { context.delete(b) }
            for d in try context.fetch(FetchDescriptor<DownloadItem>()) { context.delete(d) }
            try? context.save()
        } catch {
            check("Sync pipeline threw: \(error)", false)
        }

        print("\(tag): DONE — \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
    }
}
#endif
