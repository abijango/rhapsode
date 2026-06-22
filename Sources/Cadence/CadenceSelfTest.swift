#if DEBUG
import AVFoundation
import CadenceKit
import Foundation
import SwiftData

/// WP3 verification: drives the real `CadenceRenderer` over synthetic PCM with known silences and
/// checks the end-to-end invariants that unit tests on the pure pieces can't — that the streaming
/// AAC writer produces a shorter, decodable `.m4a`, that the source↔trimmed map round-trips on
/// kept audio, and that chapter-chunk stitching holds. Runs only under `-phase0selftest`.
extension PhaseZeroSelfTest {
    static func runCadenceChecks() -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        let sampleRate = 44_100.0
        // tone[0,1) silence[1,3) tone[3,4) silence[4,6) tone[6,7) — two 2 s gaps to trim.
        let layout: [(seconds: Double, tone: Bool)] = [(1, true), (2, false), (1, true), (2, false), (1, true)]

        do {
            let source = try ContainerPaths.cacheURL(forRelativePath: "selftest-cadence-src.wav")
            let output = try ContainerPaths.cacheURL(forRelativePath: "selftest-cadence-out.m4a")
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)

            try writeSyntheticWAV(layout: layout, sampleRate: sampleRate, to: source)

            // Force chunking: a 2 s cap over a 7 s file with a chapter cut at 4 s exercises the
            // cross-chunk map stitching (multiple sub-chunks per chapter).
            var renderer = CadenceRenderer()
            renderer.maxChunkSeconds = 2.0
            let req = CadenceRenderRequest(
                sourceURL: source, cutPoints: [0, 4.0], titles: ["Ch A", "Ch B"],
                preset: .default, outputURL: output)
            let result = try renderer.render(req)

            check("Cadence: output .m4a written", FileManager.default.fileExists(atPath: output.path))
            check("Cadence: trimmed shorter than original",
                  result.trimmedDuration < result.originalDuration)
            check("Cadence: savedSeconds > 0.5 (two 2 s gaps collapsed)", result.savedSeconds > 0.5)
            check("Cadence: regions detected", result.regionCount >= 2)

            // The encoded file decodes back to ≈ the reported trimmed duration (AAC priming
            // padding keeps this within a small tolerance).
            if let decoded = try? AVAudioFile(forReading: output) {
                let decodedDuration = Double(decoded.length) / decoded.processingFormat.sampleRate
                check("Cadence: decoded output ≈ reported trimmed duration",
                      abs(decodedDuration - result.trimmedDuration) < 0.25)
            } else {
                check("Cadence: output .m4a is decodable", false)
            }

            // Map round-trips on kept audio (tone centres are bijective, slope-1 regions).
            let map = result.timelineMap
            for s in [0.5, 3.5, 6.5] {
                let back = map.toSource(map.toTrimmed(s))
                check("Cadence: map round-trips at source \(s)s", abs(back - s) < 0.05)
            }
            check("Cadence: map is shorter in trimmed than source",
                  map.trimmedDuration < map.sourceDuration)

            // Chapter marks: same count, monotonic in trimmed, source preserved.
            check("Cadence: two chapter marks emitted", result.chapters.count == 2)
            if result.chapters.count == 2 {
                check("Cadence: chapter marks monotonic in trimmed time",
                      result.chapters[1].trimmedStart >= result.chapters[0].trimmedStart)
                check("Cadence: first chapter source preserved at 0",
                      abs(result.chapters[0].sourceStart) < 0.001)
            }

            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        } catch {
            check("Cadence: render threw: \(error)", false)
        }

        // Pure window-planning: a window longer than the cap subdivides; cut points are honoured.
        let windows = CadenceRenderer.chunkWindows(cutPoints: [0, 4.0], totalDuration: 7.0, maxChunkSeconds: 2.0)
        check("Cadence: long windows subdivide (≥4 chunks)", windows.count >= 4)
        check("Cadence: windows cover the whole file",
              abs((windows.first?.start ?? -1)) < 0.001 && abs((windows.last?.end ?? -1) - 7.0) < 0.001)

        return failures
    }

    /// WP4 verification: exercises the full `CadenceRenderCoordinator` — insert an `Audiobook`
    /// backed by a real on-disk file, enqueue it, and confirm a valid `TrimmedRendition` row is
    /// written with the trimmed file on disk, decodable blobs, and idempotent re-enqueue.
    static func runCadenceCoordinatorChecks(context: ModelContext) async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        let wasEnabled = CadencePreferences.isEnabled
        CadencePreferences.isEnabled = true
        defer { CadencePreferences.isEnabled = wasEnabled }

        let layout: [(seconds: Double, tone: Bool)] = [(1, true), (2, false), (1, true), (2, false), (1, true)]
        let bookDirRel = "selftest-cadence-ab"
        var bookID: UUID?

        do {
            let rel = "\(bookDirRel)/book.wav"
            let url = try ContainerPaths.url(forRelativePath: rel)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeSyntheticWAV(layout: layout, sampleRate: 44_100, to: url)

            // Two tracks sharing one file → the M4B chapter path (one rendition, cut at 3.5 s).
            let book = Audiobook(
                title: "selftest-cadence", sourcePath: rel,
                tracks: [
                    AudiobookTrack(title: "A", fileRelPath: rel, duration: 3.5, order: 0),
                    AudiobookTrack(title: "B", fileRelPath: rel, duration: 3.5, order: 1),
                ], totalDuration: 7)
            context.insert(book)
            try context.save()
            let id = book.id
            bookID = id

            await CadenceRenderCoordinator.shared.configure(container: context.container)
            await CadenceRenderCoordinator.shared.enqueue(bookID: id)

            // Poll up to ~10 s for the background render to land its rendition.
            var rendition: TrimmedRendition?
            for _ in 0..<100 {
                try await Task.sleep(nanoseconds: 100_000_000)
                rendition = (try? context.fetch(FetchDescriptor<TrimmedRendition>()))?.first { $0.bookID == id }
                if rendition != nil { break }
            }

            check("Coordinator: rendition row written", rendition != nil)
            if let r = rendition {
                let trimmedURL = try? ContainerPaths.cacheURL(forRelativePath: r.trimmedRelPath)
                check("Coordinator: trimmed file exists on disk",
                      FileManager.default.fileExists(atPath: trimmedURL?.path ?? ""))
                check("Coordinator: savedSeconds > 0", r.savedSeconds > 0)
                check("Coordinator: tier persisted as 'default'", r.tier == "default")
                check("Coordinator: timeline map blob decodes",
                      (try? JSONDecoder().decode(CadenceTimelineMap.self, from: r.timelineMapBlob)) != nil)
                let chapters = try? JSONDecoder().decode([CadenceChapterMark].self, from: r.chapterMapBlob)
                check("Coordinator: two chapter marks persisted", chapters?.count == 2)

                // Idempotent: a second enqueue must not create a duplicate row.
                await CadenceRenderCoordinator.shared.enqueue(bookID: id)
                try await Task.sleep(nanoseconds: 600_000_000)
                let count = ((try? context.fetch(FetchDescriptor<TrimmedRendition>()))?
                    .filter { $0.bookID == id }.count) ?? 0
                check("Coordinator: idempotent re-enqueue (single row)", count == 1)

                failures += await runCadencePlaybackChecks(bookID: id, relPath: rel,
                                                            rendition: r, context: context)
            }
        } catch {
            check("Coordinator: threw: \(error)", false)
        }

        // Cleanup: renditions, book, files.
        if let id = bookID {
            for r in ((try? context.fetch(FetchDescriptor<TrimmedRendition>()))?.filter({ $0.bookID == id }) ?? []) {
                if let f = try? ContainerPaths.cacheURL(forRelativePath: r.trimmedRelPath) {
                    try? FileManager.default.removeItem(at: f)
                }
                context.delete(r)
            }
            for b in ((try? context.fetch(FetchDescriptor<Audiobook>()))?.filter({ $0.id == id }) ?? []) {
                context.delete(b)
            }
            try? context.save()
        }
        if let dir = try? ContainerPaths.url(forRelativePath: bookDirRel) {
            try? FileManager.default.removeItem(at: dir)
        }
        return failures
    }

    /// WP5 verification: selection contract + the REAL player seek/read wiring. Loads an
    /// `AudiobookPlayer` on a trimmed rendition and seeks to a discriminating source time so a
    /// missed mapping site or an inverted direction is caught (not just the map math, which WP3
    /// already covers).
    static func runCadencePlaybackChecks(bookID: UUID, relPath: String,
                                         rendition: TrimmedRendition, context: ModelContext) async -> Int {
        var failures = 0
        func check(_ name: String, _ condition: Bool) {
            print("\(tag): \(condition ? "PASS" : "FAIL") — \(name)")
            if !condition { failures += 1 }
        }

        // Selection contract: on while enabled, nil while disabled.
        let onResult = AudiobookPlayer.selectTrimmedSource(bookID: bookID, relPath: relPath,
                                                           tier: "default", context: context)
        check("Playback: selection returns trimmed source when enabled", onResult != nil)
        CadencePreferences.isEnabled = false
        let offResult = AudiobookPlayer.selectTrimmedSource(bookID: bookID, relPath: relPath,
                                                            tier: "default", context: context)
        check("Playback: selection returns nil when feature disabled", offResult == nil)
        CadencePreferences.isEnabled = true

        guard let map = try? JSONDecoder().decode(CadenceTimelineMap.self, from: rendition.timelineMapBlob),
              let book = (try? context.fetch(FetchDescriptor<Audiobook>()))?.first(where: { $0.id == bookID }) else {
            check("Playback: prerequisites (map + book) available", false)
            return failures
        }

        let player = AudiobookPlayer()
        player.load(book, context: context)

        // Wait for the trimmed item to become ready (it must, before a precise seek lands).
        var ready = false
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if player.debugItemReady { ready = true; break }
        }
        check("Playback: trimmed item ready", ready)
        check("Playback: loaded the trimmed file (activeMap set)", player.debugIsTrimmed)

        // Seek to a source time mid-kept-region: toTrimmed(3.5)≈1.9, vs 3.5 (missed site) vs
        // ~3.8 (inverted) — all separated by >1 s, so the tight tolerance pins the wiring.
        let sourceSeek = 3.5
        let expectedPlayer = map.toTrimmed(sourceSeek)
        player.debugSeek(toSourceTime: sourceSeek)

        var landed = player.debugPlayerTimeSeconds
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            landed = player.debugPlayerTimeSeconds
            if abs(landed - expectedPlayer) < 0.25 { break }
        }
        check("Playback: player landed at toTrimmed(source) — \(String(format: "%.2f", landed)) ≈ \(String(format: "%.2f", expectedPlayer))",
              abs(landed - expectedPlayer) < 0.25)
        check("Playback: bookTime round-trips to source 3.5 — \(String(format: "%.2f", player.debugBookTime))",
              abs(player.debugBookTime - sourceSeek) < 0.25)

        player.teardown()
        return failures
    }

    /// Build mono float32 PCM from a tone/silence layout and write it as a WAV the renderer reads.
    private static func writeSyntheticWAV(layout: [(seconds: Double, tone: Bool)],
                                          sampleRate: Double, to url: URL) throws {
        var samples: [Float] = []
        for seg in layout {
            let n = Int(seg.seconds * sampleRate)
            if seg.tone {
                for i in 0..<n { samples.append(0.3 * sinf(2 * .pi * 220 * Float(i) / Float(sampleRate))) }
            } else {
                samples.append(contentsOf: repeatElement(0, count: n))
            }
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try AudioIO.writeWAV(buffer, to: url)
    }
}
#endif
