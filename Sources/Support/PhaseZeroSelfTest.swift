#if DEBUG
import Foundation
import SwiftData
import UIKit

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

        // 6. E-book import + Foliate progress + local EPUB validation + reader open.
        do {
            let mock = MockLibrarySource()
            if let epub = try await mock.listFolder("/Books").first {
                let dest = try ContainerPaths.url(forRelativePath: "selftest-bk/\(epub.name)")
                try await mock.download(epub, to: dest)
                let book = try await EbookImporter.makeBook(fromLocal: dest)
                check("EPUB title parsed", book.title == "Sample Book")
                check("EPUB author parsed", book.author == "Sample Author")
                check(
                    "EPUB file validates",
                    EPUBFileValidator.validateLocalEPUB(at: dest) == nil
                )

                // Foliate progress JSON (shelf fractionComplete path).
                let progress = FoliateProgress(
                    cfi: "epubcfi(/6/4!/4/2/2/2)",
                    locations: .init(totalProgression: 0.42)
                )
                book.readingLocator = progress.jsonString
                check(
                    "Foliate fractionComplete from locator",
                    abs(book.fractionComplete - 0.42) < 0.001
                )
                check(
                    "FoliateProgress parse round-trip",
                    FoliateProgress.parse(progress.jsonString ?? "")?.cfi == progress.cfi
                )
                check(
                    "FoliateProgress.cfi extracts engine cfi",
                    FoliateProgress.cfi(fromLocatorJSON: progress.jsonString) == progress.cfi
                )
                // Legacy Readium-shaped locator: fraction only.
                let legacy =
                    #"{"href":"ch1.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.25}}"#
                check(
                    "Legacy locator fraction still readable",
                    FoliateProgress.fraction(fromLocatorJSON: legacy) == 0.25
                )
                check(
                    "Legacy locator has no Foliate cfi",
                    FoliateProgress.cfi(fromLocatorJSON: legacy) == nil
                )

                context.insert(book)
                try? context.save()

                // Full Foliate open (WKWebView + scheme). Needs main run loop; may be
                // slow cold-start. Fail soft on shell timeout so CI without UI still
                // gets progress/validation coverage.
                let reader = FoliateWebReader()
                reader.prepareWebViewIfNeeded()
                // Host off-screen so WebKit paints / runs the scheme handler reliably.
                let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
                if let wv = reader.webView {
                    wv.frame = host.bounds
                    host.addSubview(wv)
                }
                await reader.open(book, context: context)
                if let err = reader.loadError, !reader.isOpen {
                    check("Foliate reader open (shell/book): \(err)", false)
                } else {
                    check("Foliate reader open OK", reader.isOpen)
                    check("Foliate reader no load error", reader.loadError == nil)
                    // Sample Book TOC is 2 entries when nav is present.
                    check("Foliate TOC non-empty", reader.toc.count >= 1)
                }

                context.delete(book)
                try? context.save()

                try? FileManager.default.removeItem(
                    at: try ContainerPaths.url(forRelativePath: "selftest-bk"))
            } else {
                check("Had an EPUB fixture", false)
            }

            // Empty-path validator smoke.
            let missing = URL(fileURLWithPath: "/tmp/rhapsode-missing-\(UUID().uuidString).epub")
            check(
                "Validator flags missing file",
                EPUBFileValidator.validateLocalEPUB(at: missing) != nil
            )

            // Path 3a: partialMD5 JS shift semantics + stable hash for sample EPUB.
            check("partialMD5 i=-1 shift is 0", PartialMD5.jsShiftLeft(1024, -2) == 0)
            check("partialMD5 i=0 shift is 1024", PartialMD5.jsShiftLeft(1024, 0) == 1024)
            check("partialMD5 i=1 shift is 4096", PartialMD5.jsShiftLeft(1024, 2) == 4096)
            if let epubURL = try? ContainerPaths.url(forRelativePath: "selftest-bk").deletingLastPathComponent()
                .appendingPathComponent("Books") {
                // Prefer fixture if still around after cleanup; else re-download briefly.
                _ = epubURL
            }
            do {
                let mock = MockLibrarySource()
                if let epub = try await mock.listFolder("/Books").first {
                    let dest = try ContainerPaths.url(forRelativePath: "selftest-md5/\(epub.name)")
                    try await mock.download(epub, to: dest)
                    let h1 = try PartialMD5.hash(fileAt: dest)
                    let h2 = try PartialMD5.hash(fileAt: dest)
                    check("partialMD5 length 32", h1.count == 32)
                    check("partialMD5 stable", h1 == h2)
                    check("partialMD5 hex", h1.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil)
                    try? FileManager.default.removeItem(
                        at: try ContainerPaths.url(forRelativePath: "selftest-md5"))
                }
            } catch {
                check("partialMD5 sample failed: \(error)", false)
            }
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

        failures += runSmbMappingChecks()
        failures += await runPhase3Checks(context: context)
        failures += runPhase4aChecks()
        failures += runCollectionChecks(context: context)
        failures += await runCollectionSyncChecks(context: context)
        failures += await runPhase5Checks(context: context)
        // Batch SmartSpeech self-tests were removed with the batch pre-render feature; live
        // silence-trimming has its own harness (LiveSmartSpeechSelfTest, arg -livesmartspeechselftest).
        print("\(tag): DONE — \(failures == 0 ? "ALL PASS" : "\(failures) FAILED")")
        // Headless mode only (run() is invoked solely under `-phase0selftest`):
        // exit so stdout flushes (C `exit` flushes stdio; the app otherwise never
        // terminates and buffered `print` output is lost) and the process yields a
        // pass/fail code. Lets `open -W --stdout` capture the result on Mac Catalyst,
        // where a directly-exec'd GUI binary creates no window scene.
        exit(failures == 0 ? 0 : 1)
    }

    // -------------------------------------------------------------------------
    // SMB path / disconnect mapping
    // -------------------------------------------------------------------------
    static func runSmbMappingChecks() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        let mapped = SmbLibrarySource.mapLibraryPath(
            "/Audiobooks/Harry Potter and the Goblet of Fire (Full-Cast Edition).m4b")
        check(
            "SMB: mapLibraryPath keeps the filename",
            mapped.hasSuffix("Harry Potter and the Goblet of Fire (Full-Cast Edition).m4b"))

        let enotconn = POSIXError(
            .ENOTCONN,
            userInfo: [NSLocalizedDescriptionKey: "SMB2 server not connected."]
        )
        check("SMB: isDisconnected recognizes ENOTCONN", SmbLibrarySource.isDisconnected(enotconn))

        let mappedError = SmbLibrarySource.mapError(
            enotconn, context: "Download “Audiobooks/book.m4b”")
        check("SMB: isDisconnected recognizes mapped code 57", SmbLibrarySource.isDisconnected(mappedError))
        let text = mappedError.errorDescription ?? ""
        check("SMB: mapError mentions Retry for code 57", text.contains("[code 57]") && text.contains("Retry"))

        let missing = POSIXError(.ENOENT, userInfo: [:])
        check("SMB: isDisconnected ignores ENOENT", !SmbLibrarySource.isDisconnected(missing))

        return failures
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

        // P3-3b. TaskPayload with MP3-folder group fields round-trips; legacy payloads
        //       without group fields decode with nil defaults.
        do {
            let grouped = TaskPayload(
                itemID: UUID(),
                destRelPath: "Audiobooks/MyBook/track01.mp3",
                kind: .audiobooks,
                title: "track01.mp3",
                groupID: "group-abc",
                groupFolderRelPath: "Audiobooks/MyBook",
                groupTitle: "My Book"
            )
            let decoded = try JSONDecoder().decode(
                TaskPayload.self, from: try JSONEncoder().encode(grouped))
            check("P3b: TaskPayload round-trips groupID", decoded.groupID == grouped.groupID)
            check("P3b: TaskPayload round-trips groupFolderRelPath",
                  decoded.groupFolderRelPath == grouped.groupFolderRelPath)
            check("P3b: TaskPayload round-trips groupTitle", decoded.groupTitle == grouped.groupTitle)

            let legacyJSON = """
            {"itemID":"\(UUID().uuidString)","destRelPath":"Books/a.epub","kind":"books","title":"a"}
            """
            let legacy = try JSONDecoder().decode(TaskPayload.self, from: Data(legacyJSON.utf8))
            check("P3b: legacy TaskPayload decodes with nil group fields", legacy.groupID == nil)
        } catch {
            check("P3b: TaskPayload group encode/decode threw: \(error)", false)
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

        // P3-6. MP3-folder group completion: import only when every child is `.done`
        //       and none are `.failed`.
        do {
            let groupID = "selftest-group"
            let done1 = DownloadItem(
                remoteEntryID: "c1", title: "01.mp3", kind: .audiobooks, state: .done,
                groupID: groupID, groupFolderRelPath: "Audiobooks/Book")
            let done2 = DownloadItem(
                remoteEntryID: "c2", title: "02.mp3", kind: .audiobooks, state: .done,
                groupID: groupID, groupFolderRelPath: "Audiobooks/Book")
            let pending = DownloadItem(
                remoteEntryID: "c3", title: "03.mp3", kind: .audiobooks, state: .downloading,
                groupID: groupID, groupFolderRelPath: "Audiobooks/Book")
            let failed = DownloadItem(
                remoteEntryID: "c4", title: "04.mp3", kind: .audiobooks, state: .failed,
                groupID: groupID, groupFolderRelPath: "Audiobooks/Book")

            check("P3b: shouldImportGroup false while a child is downloading",
                  !BackgroundDownloader.shouldImportGroup(
                      items: [done1, done2, pending], groupID: groupID))
            check("P3b: shouldImportGroup true when every child is done",
                  BackgroundDownloader.shouldImportGroup(
                      items: [done1, done2], groupID: groupID))
            check("P3b: shouldImportGroup false when any child failed",
                  !BackgroundDownloader.shouldImportGroup(
                      items: [done1, failed], groupID: groupID))

            _ = pending
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

        let dummy = Audiobook(title: "Test", sourcePath: "Audiobooks/Test.m4b")
        check("RootPlayer: browsing + tabs → none",
              RootPlayerPresentation.surface(intent: .browsing, layout: .tabs) == .none)
        check("RootPlayer: browsing + split → none",
              RootPlayerPresentation.surface(intent: .browsing, layout: .split) == .none)
        check("RootPlayer: showing + tabs → cover",
              RootPlayerPresentation.surface(intent: .showing(dummy), layout: .tabs) == .cover)
        check("RootPlayer: showing + split → detail",
              RootPlayerPresentation.surface(intent: .showing(dummy), layout: .split) == .detail)
        check("RootPlayer: mini hidden with no playing book",
              !RootPlayerPresentation.showsMiniPlayer(hasPlayingBook: false, surface: .none))
        check("RootPlayer: mini hidden on cover",
              !RootPlayerPresentation.showsMiniPlayer(hasPlayingBook: true, surface: .cover))
        check("RootPlayer: mini hidden on detail",
              !RootPlayerPresentation.showsMiniPlayer(hasPlayingBook: true, surface: .detail))
        check("RootPlayer: mini visible on shelf when playing",
              RootPlayerPresentation.showsMiniPlayer(hasPlayingBook: true, surface: .none))

        // Design system: the fixed regular cover width must be larger than the compact minimum
        // so iPad/Mac get bigger covers than iPhone.
        check("DS.Shelf: iPad cover width > compact minWidth",
              DS.Shelf.coverWidthPad > DS.Shelf.minCoverWidth)
        check("DS.Shelf: Mac cover width > iPad",
              DS.Shelf.coverWidthMac > DS.Shelf.coverWidthPad)
        check("DS.Shelf: compact two-column width > old adaptive minimum",
              DS.Shelf.compactCoverWidth(forUsableWidth: 361) > DS.Shelf.minCoverWidth)
        check("DS.Shelf: compact uses two columns on phone-width",
              DS.Shelf.compactColumnCount(forUsableWidth: 361) == 2)

        // Library shelf: Continue section + search helpers.
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 2_000)
        let inProgress = Audiobook(
            title: "Continue Me", sourcePath: "Audiobooks/Continue.m4b",
            lastTrackIndex: 1, lastOffsetSeconds: 30, totalDuration: 100,
            progressUpdatedAt: recent)
        let finished = Audiobook(
            title: "Done", sourcePath: "Audiobooks/Done.m4b",
            lastTrackIndex: 0, lastOffsetSeconds: 100, totalDuration: 100,
            progressUpdatedAt: recent)
        let untouched = Audiobook(title: "Fresh", sourcePath: "Audiobooks/Fresh.m4b")
        let continueAB = LibraryShelf.continueAudiobooks([finished, untouched, inProgress])
        check("LibraryShelf: continue audiobooks in-progress only", continueAB.count == 1 && continueAB[0].title == "Continue Me")
        check("LibraryShelf: continue audiobooks most recent first",
              LibraryShelf.continueAudiobooks([
                  Audiobook(title: "A", sourcePath: "a", lastTrackIndex: 0, lastOffsetSeconds: 10,
                            totalDuration: 100, progressUpdatedAt: old),
                  Audiobook(title: "B", sourcePath: "b", lastTrackIndex: 0, lastOffsetSeconds: 10,
                            totalDuration: 100, progressUpdatedAt: recent),
              ]).first?.title == "B")
        check("LibraryShelf: audiobook search matches title",
              LibraryShelf.matchesAudiobook(inProgress, query: "continue"))
        check("LibraryShelf: audiobook search empty query matches all",
              LibraryShelf.matchesAudiobook(inProgress, query: "   "))

        let reading = Book(
            title: "Reading", fileRelPath: "Books/Reading.epub",
            readingLocator: "{}", progressUpdatedAt: recent, readingSeconds: 60)
        let unread = Book(title: "Unread", fileRelPath: "Books/Unread.epub")
        check("LibraryShelf: continue ebooks in-progress only",
              LibraryShelf.continueEbooks([reading, unread]).count == 1)

        return failures
    }

    // -------------------------------------------------------------------------
    // Collections — user-defined shelf tags
    // -------------------------------------------------------------------------
    static func runCollectionChecks(context: ModelContext) -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        do {
            for c in try context.fetch(FetchDescriptor<LibraryCollection>()) { context.delete(c) }
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try context.save()

            let store = CollectionStore(context: context)
            let sciFi = try store.create(name: "Sci-Fi", kind: .audiobooks)
            check("Collections: create", sciFi.name == "Sci-Fi" && sciFi.kind == .audiobooks)

            var dupFailed = false
            do { _ = try store.create(name: "sci-fi", kind: .audiobooks); dupFailed = false }
            catch { dupFailed = true }
            check("Collections: duplicate name rejected", dupFailed)

            let book = Audiobook(title: "Dune", sourcePath: "Audiobooks/Dune.m4b")
            context.insert(book)
            try context.save()
            try store.toggleMembership(collection: sciFi, audiobook: book)
            check("Collections: assign audiobook", store.isMember(sciFi, audiobook: book))
            check("LibraryShelf: inCollection filter passes member",
                  LibraryShelf.inCollection(book.collections, filterID: sciFi.id))
            check("LibraryShelf: inCollection filter rejects non-member",
                  !LibraryShelf.inCollection(book.collections, filterID: UUID()))

            try store.rename(sciFi, to: "Science Fiction")
            check("Collections: rename", sciFi.name == "Science Fiction")

            try store.delete(sciFi)
            check("Collections: delete clears membership", book.collections.isEmpty)

            for c in try context.fetch(FetchDescriptor<LibraryCollection>()) { context.delete(c) }
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try context.save()
        } catch {
            check("Collections: pipeline threw: \(error)", false)
        }

        return failures
    }

    // -------------------------------------------------------------------------
    // Collections — cross-device manifest sync
    // -------------------------------------------------------------------------
    static func runCollectionSyncChecks(context: ModelContext) async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        let sample = CollectionsManifest(
            kind: .audiobooks,
            collections: [CollectionWire(id: UUID(), name: "Sci-Fi", memberKeys: ["Audiobooks/Dune.m4b"])],
            updatedAt: new)
        if let data = try? PlaybackProgress.encoder.encode(sample),
           let back = try? PlaybackProgress.decoder.decode(CollectionsManifest.self, from: data) {
            check("CollectionSync: manifest JSON round-trips", back == sample)
        } else {
            check("CollectionSync: manifest JSON round-trips", false)
        }

        check("CollectionSync: isNewer when local nil", sample.isNewer(than: nil))
        check("CollectionSync: isNewer when remote newer", sample.isNewer(than: old))
        check("CollectionSync: not newer when local newer",
              !sample.isNewer(than: Date(timeIntervalSince1970: 3_000)))

        check("CollectionSync: audiobooks path",
              DropboxProgressSync.collectionsPath(for: .audiobooks)
              == "\(DropboxProgressSync.folder)/collections-audiobooks.json")
        check("CollectionSync: books path",
              DropboxProgressSync.collectionsPath(for: .books)
              == "\(DropboxProgressSync.folder)/collections-books.json")

        do {
            for c in try context.fetch(FetchDescriptor<LibraryCollection>()) { context.delete(c) }
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try context.save()

            let collectionID = UUID()
            let key = "Audiobooks/SyncCollection.m4b"
            let book = Audiobook(title: "Sync Collection", sourcePath: key)
            context.insert(book)
            try context.save()

            let remote = CollectionsManifest(
                kind: .audiobooks,
                collections: [CollectionWire(id: collectionID, name: "Imported", memberKeys: [key])],
                updatedAt: new)
            let mock = MockProgressSync()
            try await mock.pushCollections(remote)

            CollectionsSyncState.setUpdatedAt(old, for: .audiobooks)
            let sync = SyncManager(source: MockLibrarySource(), context: context, progress: mock)
            await sync.pullAndMergeProgress()

            let imported = try context.fetch(FetchDescriptor<LibraryCollection>())
                .first { $0.id == collectionID }
            check("CollectionSync: newer remote collection imported", imported?.name == "Imported")
            check("CollectionSync: membership applied by sourcePath",
                  imported?.audiobooks.contains { $0.sourcePath == key } == true)

            // Older remote must not clobber a newer local edit (rename stamps via CollectionStore).
            if let imported {
                try CollectionStore(context: context).rename(imported, to: "Local Edit")
            }
            let staleMock = MockProgressSync()
            try await staleMock.pushCollections(remote)
            let sync2 = SyncManager(source: MockLibrarySource(), context: context, progress: staleMock)
            await sync2.pullAndMergeProgress()
            let afterStale = try context.fetch(FetchDescriptor<LibraryCollection>())
                .first { $0.id == collectionID }
            check("CollectionSync: older remote does not overwrite newer local",
                  afterStale?.name == "Local Edit")

            // Push guard keeps a strictly newer stored manifest.
            let guardMock = MockProgressSync()
            try await guardMock.pushCollections(remote)
            let older = CollectionsManifest(kind: .audiobooks, collections: [], updatedAt: old)
            try await guardMock.pushCollections(older)
            let stored = try await guardMock.pullCollections(kind: .audiobooks)
            check("CollectionSync: push guard keeps newer manifest",
                  stored?.collections.first?.name == "Imported")

            for c in try context.fetch(FetchDescriptor<LibraryCollection>()) { context.delete(c) }
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try context.save()
            CollectionsSyncState.setUpdatedAt(old, for: .audiobooks)
            CollectionsSyncState.setUpdatedAt(old, for: .books)
        } catch {
            check("CollectionSync: pipeline threw: \(error)", false)
        }

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

        // readingSeconds is optional for back-compat; present values round-trip.
        let ebookSample = PlaybackProgress(
            key: "Books/ReadTest.epub", kind: .books,
            lastTrackIndex: 0, lastOffsetSeconds: 0,
            readingLocatorJSON: "{\"href\":\"/\"}", readingSeconds: 3600, updatedAt: new)
        if let data = try? PlaybackProgress.encoder.encode(ebookSample),
           let back = try? PlaybackProgress.decoder.decode(PlaybackProgress.self, from: data) {
            check("P5: PlaybackProgress readingSeconds round-trips", back.readingSeconds == 3600)
        } else {
            check("P5: PlaybackProgress readingSeconds round-trips", false)
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

        // E-book readingSeconds max-merge survives a stale position remote.
        do {
            for b in try context.fetch(FetchDescriptor<Book>()) { context.delete(b) }
            try? context.save()

            let key = "Books/ReadingMerge.epub"
            let local = Book(title: "Reading Merge", fileRelPath: key,
                             readingLocator: "{\"href\":\"/\"}", progressUpdatedAt: old,
                             readingSeconds: 100)
            context.insert(local)
            try context.save()

            let remote = PlaybackProgress(
                key: key, kind: .books,
                lastTrackIndex: 0, lastOffsetSeconds: 0,
                readingLocatorJSON: "{\"href\":\"/ch2\"}", readingSeconds: 250, updatedAt: new)
            let mock = MockProgressSync(seed: [remote])
            let sync = SyncManager(source: MockLibrarySource(), context: context, progress: mock)
            await sync.pullAndMergeProgress()
            check("P5: ebook readingSeconds max-merged", local.readingSeconds == 250)
            check("P5: newer ebook position applied", local.progressUpdatedAt == new)

            for b in try context.fetch(FetchDescriptor<Book>()) { context.delete(b) }
            try? context.save()
        } catch {
            check("P5: ebook merge threw: \(error)", false)
        }

        var box = ProgressOutbox()
        box.insertAudiobook("Audiobooks/Outbox.m4b")
        box.insertLifetimeStats()
        ProgressOutboxStore.save(box)
        let loaded = ProgressOutboxStore.load()
        check("P5: outbox persists audiobook key", loaded.audiobookKeys.contains("Audiobooks/Outbox.m4b"))
        check("P5: outbox pending count", loaded.pendingCount == 2)
        ProgressOutboxStore.save(ProgressOutbox())

        do {
            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try? context.save()
            let key = "Audiobooks/TrueSum.m4b"
            let local = Audiobook(
                title: "True Sum", sourcePath: key,
                smartSpeechSavedSeconds: 10, listenedSeconds: 40,
                myListenedSeconds: 40, mySmartSpeechSavedSeconds: 10)
            context.insert(local)
            try context.save()

            let mock = MockProgressSync()
            try await mock.pushBookContribution(DeviceBookContribution(
                deviceId: ProgressDeviceIdentity.deviceId, key: key, kind: .audiobooks,
                listenedSeconds: 40, savedSeconds: 10, updatedAt: new))
            try await mock.pushBookContribution(DeviceBookContribution(
                deviceId: "other-device", key: key, kind: .audiobooks,
                listenedSeconds: 20, savedSeconds: 5, updatedAt: new))
            try await mock.pushDeviceStats(DeviceStatsRecord(
                deviceId: ProgressDeviceIdentity.deviceId,
                savedSeconds: 10, playedSeconds: 40, updatedAt: new))
            try await mock.pushDeviceStats(DeviceStatsRecord(
                deviceId: "other-device",
                savedSeconds: 5, playedSeconds: 20, updatedAt: new))

            let sync = SyncManager(source: MockLibrarySource(), context: context, progress: mock)
            await sync.pullAndMergeProgress()
            check("P5: per-book listened is true-sum", local.listenedSeconds == 60)
            check("P5: per-book saved is true-sum", local.smartSpeechSavedSeconds == 15)
            check("P5: this device contribution preserved", local.myListenedSeconds == 40)

            for a in try context.fetch(FetchDescriptor<Audiobook>()) { context.delete(a) }
            try? context.save()
        } catch {
            check("P5: true-sum threw: \(error)", false)
        }

        return failures
    }
}
#endif
