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
                // Fixture folder ships a cover.jpg, so now-playing artwork is built
                // during playback — exercises the MediaPlayer artwork path that
                // crashed when its handler was main-actor-isolated.
                check("MP3 folder cover extracted", folder.coverPath != nil)
                context.insert(folder)
                try? context.save()
                let p1 = AudiobookPlayer()
                p1.load(folder, context: context)
                // Actually play briefly so the periodic time observer + now-playing
                // artwork handler fire — both previously crashed off the main actor.
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

        failures += await runPhase3Checks(context: context)
        failures += runPhase4aChecks()
        failures += await runPhase5Checks(context: context)
        failures += runCadenceChecks()
        failures += runCadenceGatingChecks()
        failures += runCadenceStatChecks()
        failures += runCadenceBookStatChecks()
        failures += runCadenceSettingsChecks()
        failures += await runCadenceCoordinatorChecks(context: context)
        failures += runCadenceCacheChecks(context: context)
        failures += await runCadenceEdgeChecks(context: context)
        failures += await runCadenceResumeChecks(context: context)
        failures += runCadenceQAChecks(context: context)
        failures += await runCadenceTierUIChecks(context: context)
        print("\(tag): DONE — \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
        // Headless mode only (run() is invoked solely under `-phase0selftest`):
        // exit so stdout flushes (C `exit` flushes stdio; the app otherwise never
        // terminates and buffered `print` output is lost) and the process yields a
        // pass/fail code. Lets `open -W --stdout` capture the result on Mac Catalyst,
        // where a directly-exec'd GUI binary creates no window scene.
        exit(failures == 0 ? 0 : 1)
    }

    // -------------------------------------------------------------------------
    // Phase 3 — Background sync checks
    // -------------------------------------------------------------------------
    /// Headlessly testable Phase 3 invariants. Does NOT touch the live URLSession
    /// (background session creation is a one-time per-identifier side-effect that
    /// must not run twice in the same process). Returns number of failures.
    static func runPhase3Checks(context: ModelContext) async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        // P3-1. ASCII-escape round-trip: non-ASCII path escapes to all-ASCII, then
        //       decodes back to the original string via JSONSerialization.
        do {
            let path = "/Café/naïve résumé.epub"
            let arg = String(data: try JSONEncoder().encode(["path": path]), encoding: .utf8)!
            let escaped = DropboxSource.asciiEscapeJSON(arg)
            let isAllASCII = escaped.unicodeScalars.allSatisfy { $0.value <= 127 }
            check("P3: asciiEscapeJSON produces all-ASCII output", isAllASCII)

            if let decoded = try? JSONSerialization.jsonObject(
                with: Data(escaped.utf8)) as? [String: String] {
                check("P3: asciiEscapeJSON decodes back to original path", decoded["path"] == path)
            } else {
                check("P3: asciiEscapeJSON round-trip parse succeeded", false)
            }
        } catch {
            check("P3: asciiEscapeJSON threw: \(error)", false)
        }

        // P3-2. ASCII-escape is a no-op on already-ASCII strings.
        do {
            let ascii = "{\"path\": \"/Audiobooks/sample.m4b\"}"
            check("P3: asciiEscapeJSON is identity on ASCII input",
                  DropboxSource.asciiEscapeJSON(ascii) == ascii)
        }

        // P3-3. TaskPayload encode→decode round-trip (mapping that survives app kills).
        do {
            let id = UUID()
            let original = TaskPayload(
                itemID: id,
                destRelPath: "Books/sample.epub",
                kind: .books,
                title: "Sample Book"
            )
            let data = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(TaskPayload.self, from: data)
            check("P3: TaskPayload round-trips itemID", decoded.itemID == original.itemID)
            check("P3: TaskPayload round-trips destRelPath", decoded.destRelPath == original.destRelPath)
            check("P3: TaskPayload round-trips kind", decoded.kind == original.kind)
            check("P3: TaskPayload round-trips title", decoded.title == original.title)
        } catch {
            check("P3: TaskPayload encode/decode threw: \(error)", false)
        }

        // P3-4. downloadRequest(for:) sets Authorization + escaped Dropbox-API-Arg.
        //       Expiry is 1 hour in the future so validAccessToken() won't try to
        //       refresh (which would require a network call).
        do {
            let kc = KeychainTokenStore(service: "selftest3.rhapsode.dropbox", account: "t3")
            try? kc.clear()
            let futureExpiry = Date(timeIntervalSinceNow: 3600)
            let tokens = DropboxTokens(
                refreshToken: "r3", accessToken: "test-access-token-p3",
                accessTokenExpiry: futureExpiry
            )
            try kc.save(tokens)
            defer { try? kc.clear() }

            let dbx = DropboxSource(keychain: kc)
            let nonASCIIPath = "/Audiobooks/Café au lait.m4b"
            let req = try await dbx.downloadRequest(for: nonASCIIPath)

            let auth = req.value(forHTTPHeaderField: "Authorization")
            check("P3: downloadRequest sets Authorization header",
                  auth == "Bearer test-access-token-p3")

            let apiArg = req.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? ""
            let isAllASCII = apiArg.unicodeScalars.allSatisfy { $0.value <= 127 }
            check("P3: downloadRequest Dropbox-API-Arg is ASCII", isAllASCII)
            check("P3: downloadRequest Dropbox-API-Arg is non-empty", !apiArg.isEmpty)
        } catch {
            check("P3: downloadRequest threw: \(error)", false)
        }

        // P3-5. Launch-reconciliation pure logic: orphanedItems correctly identifies
        //       items whose IDs have no corresponding live task.
        do {
            let liveID = UUID()
            let orphanID = UUID()

            let liveItem = DownloadItem(
                id: liveID, remoteEntryID: "r1", title: "live",
                kind: .books, state: .downloading
            )
            let orphanItem = DownloadItem(
                id: orphanID, remoteEntryID: "r2", title: "orphan",
                kind: .books, state: .downloading
            )
            let doneItem = DownloadItem(
                id: UUID(), remoteEntryID: "r3", title: "done",
                kind: .books, state: .done
            )
            context.insert(liveItem)
            context.insert(orphanItem)
            context.insert(doneItem)
            try? context.save()

            let liveTaskIDs: Set<UUID> = [liveID]
            // #Predicate cannot compare enum cases; fetch all and filter in-memory.
            let all = (try? context.fetch(FetchDescriptor<DownloadItem>())) ?? []
            let downloading = all.filter { $0.state == .downloading }

            let toFail = BackgroundDownloader.orphanedItems(
                downloading: downloading,
                liveTaskIDs: liveTaskIDs
            )

            check("P3: orphanedItems returns exactly 1 orphan", toFail.count == 1)
            check("P3: orphanedItems identifies the orphan by ID",
                  toFail.first?.id == orphanID)

            context.delete(liveItem)
            context.delete(orphanItem)
            context.delete(doneItem)
            try? context.save()
        }

        return failures
    }

    // -------------------------------------------------------------------------
    // Phase 4a — iPad adaptive layout checks
    // -------------------------------------------------------------------------
    /// Returns the number of failures (0 = all pass).
    static func runPhase4aChecks() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        // The RootLayoutMode resolution function is the single production branch:
        // compact → .tabs, regular → .split, nil → .tabs (treats unknown as compact).
        check("RootLayoutMode: compact → tabs",   RootLayoutMode.resolve(.compact)  == .tabs)
        check("RootLayoutMode: regular → split",  RootLayoutMode.resolve(.regular)  == .split)
        check("RootLayoutMode: nil → tabs",       RootLayoutMode.resolve(nil)        == .tabs)

        // Design system: the wider regular minimum must be strictly larger than
        // the compact minimum so the adaptive grid actually uses more columns.
        check("DS.Shelf: regular minWidth > compact minWidth",
              DS.Shelf.minCoverWidthRegular > DS.Shelf.minCoverWidth)

        return failures
    }

    // -------------------------------------------------------------------------
    // Phase 5 — Cross-device progress sync (Dropbox app-folder) checks
    // -------------------------------------------------------------------------
    /// Headlessly testable Phase 5 invariants. Uses an in-memory `MockProgressSync`
    /// (the real `DropboxProgressSync` network path is device/live-only, like the
    /// rest of the Dropbox layer). Returns number of failures.
    static func runPhase5Checks(context: ModelContext) async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        // PlaybackProgress JSON round-trips (the cross-device + Android wire format).
        let sample = PlaybackProgress(
            key: "Audiobooks/Sync Tëst.m4b", kind: .audiobooks,
            lastTrackIndex: 3, lastOffsetSeconds: 42.5,
            readingLocatorJSON: nil, updatedAt: new)
        if let data = try? PlaybackProgress.encoder.encode(sample),
           let back = try? PlaybackProgress.decoder.decode(PlaybackProgress.self, from: data) {
            check("P5: PlaybackProgress JSON round-trips", back == sample)
        } else {
            check("P5: PlaybackProgress JSON round-trips", false)
        }

        // Last-writer-wins decision.
        check("P5: isNewer when local nil",   sample.isNewer(than: nil))
        check("P5: isNewer when remote newer", sample.isNewer(than: old))
        check("P5: not newer when local newer", !sample.isNewer(than: Date(timeIntervalSince1970: 3_000)))

        // Remote file path: stable, ASCII, .json, and distinct per key.
        let pathA = DropboxProgressSync.path(for: "Audiobooks/Foo.m4b")
        let pathA2 = DropboxProgressSync.path(for: "Audiobooks/Foo.m4b")
        let pathB = DropboxProgressSync.path(for: "Books/Bar.epub")
        check("P5: sync path is stable for a key", pathA == pathA2)
        check("P5: sync path differs per key", pathA != pathB)
        check("P5: sync path is ASCII .json under folder",
              pathA.hasPrefix(DropboxProgressSync.folder + "/") && pathA.hasSuffix(".json")
              && pathA.allSatisfy { $0.isASCII })

        // SyncManager merge: a newer remote record updates the matching local model.
        do {
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try? context.save()

            let key = "Audiobooks/MergeTest.m4b"
            let local = Audiobook(title: "Merge Test", sourcePath: key,
                                  lastTrackIndex: 0, lastOffsetSeconds: 0,
                                  progressUpdatedAt: old)
            context.insert(local)
            try context.save()

            let newerRemote = PlaybackProgress(
                key: key, kind: .audiobooks,
                lastTrackIndex: 5, lastOffsetSeconds: 99, readingLocatorJSON: nil, updatedAt: new)
            let mock = MockProgressSync(seed: [newerRemote])
            let sync = SyncManager(source: MockLibrarySource(), context: context, progress: mock)
            await sync.pullAndMergeProgress()
            check("P5: newer remote progress applied to local", local.lastTrackIndex == 5)

            // Older remote must NOT clobber a newer local position.
            local.lastTrackIndex = 8
            local.progressUpdatedAt = Date(timeIntervalSince1970: 4_000)
            try context.save()
            let staleMock = MockProgressSync(seed: [PlaybackProgress(
                key: key, kind: .audiobooks,
                lastTrackIndex: 1, lastOffsetSeconds: 0, readingLocatorJSON: nil,
                updatedAt: new)])
            let sync2 = SyncManager(source: MockLibrarySource(), context: context, progress: staleMock)
            await sync2.pullAndMergeProgress()
            check("P5: older remote does not overwrite newer local", local.lastTrackIndex == 8)

            // push guard: pushing an older record must not clobber a newer stored one.
            let guardMock = MockProgressSync(seed: [newerRemote])
            try? await guardMock.push(PlaybackProgress(
                key: key, kind: .audiobooks,
                lastTrackIndex: 1, lastOffsetSeconds: 0, readingLocatorJSON: nil, updatedAt: old))
            let stored = try await guardMock.pullAll().first { $0.key == key }
            check("P5: push guard keeps newer record", stored?.lastTrackIndex == 5)

            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try? context.save()
        } catch {
            check("P5: merge pipeline threw: \(error)", false)
        }

        return failures
    }
}
#endif
