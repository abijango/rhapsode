import AVFoundation
import Foundation
import SwiftData
import CadenceKit

/// Background orchestration for Cadence rendering (WP4). A serial, one-book-at-a-time actor:
/// download-complete / toggle-on / tier-change call `enqueue(bookID:)`; the actor drains the
/// queue, rendering each book's files in the background while the heavy CPU work runs off the
/// actor (so `enqueue` never blocks the caller). Until a rendition exists, playback uses the
/// original (spec §7.2) — there is no failure path that breaks playback.
///
/// SwiftData: model reads/writes use a private `ModelContext` created on the actor; the heavy
/// render runs in a detached task over Sendable primitives only, so no `@Model` crosses actors.
actor CadenceRenderCoordinator {
    static let shared = CadenceRenderCoordinator()

    private var container: ModelContainer?
    private var queue: [UUID] = []
    private var isRunning = false
    private var currentBookID: UUID?
    private var activeTask: Task<Void, Never>?

    /// Wire the container at launch. Drains anything enqueued before configuration.
    func configure(container: ModelContainer) {
        self.container = container
        startNextIfIdle()
    }

    /// Request a render of all of a book's files for its resolved tier, if Cadence is active for
    /// this book. Idempotent and cheap — returns immediately. Gating flows through the book's
    /// `resolvedCadence` (so a per-book forced profile renders even when global is off; an "off"
    /// or DRM book is skipped). `process` re-checks authoritatively.
    func enqueue(bookID: UUID) {
        // Best-effort skip when we can resolve to .off now; otherwise queue and let process decide
        // (covers the rare enqueue-before-configure case where there is no container yet).
        if let container,
           let book = (try? ModelContext(container).fetch(FetchDescriptor<Audiobook>()))?
               .first(where: { $0.id == bookID }),
           case .off = book.resolvedCadence { return }
        if currentBookID != bookID && !queue.contains(bookID) { queue.append(bookID) }
        startNextIfIdle()
    }

    /// Cancel an in-flight or queued render (e.g. on tier change — WP9). The partial `.m4a` is
    /// discarded; a fresh `enqueue` re-renders from scratch (book-granularity resume).
    func cancel(bookID: UUID) {
        queue.removeAll { $0 == bookID }
        if currentBookID == bookID { activeTask?.cancel() }
    }

    // MARK: - Draining

    private func startNextIfIdle() {
        guard !isRunning, container != nil, !queue.isEmpty else { return }
        isRunning = true
        let bookID = queue.removeFirst()
        currentBookID = bookID
        activeTask = Task { [weak self] in
            await self?.process(bookID: bookID)
            await self?.finishCurrent()
        }
    }

    private func finishCurrent() {
        isRunning = false
        currentBookID = nil
        activeTask = nil
        startNextIfIdle()
    }

    // MARK: - One book

    private func process(bookID: UUID) async {
        guard let container else { return }
        let ctx = ModelContext(container)
        guard let book = (try? ctx.fetch(FetchDescriptor<Audiobook>()))?.first(where: { $0.id == bookID }) else { return }

        // Authoritative gate: render only when Cadence resolves to ON for this book, at the
        // resolved tier. Covers global-off-with-per-book-force-on, per-book "off", and DRM.
        guard case .on(let tier) = book.resolvedCadence else { return }
        let jobs = Self.buildJobs(for: book)

        for job in jobs {
            if Task.isCancelled { break }

            // Skip files already rendered for this exact key with the audio still present.
            if let existing = Self.existingRendition(ctx, bookID: bookID, relPath: job.relPath),
               existing.isValid(forFingerprint: job.fingerprint, tier: tier.rawValue),
               FileManager.default.fileExists(atPath: (try? ContainerPaths.cacheURL(forRelativePath: existing.trimmedRelPath))?.path ?? "") {
                existing.lastUsedAt = Date()
                try? ctx.save()
                continue
            }

            let outputRel = Self.outputRelPath(bookID: bookID, relPath: job.relPath, tier: tier)
            guard let outputURL = try? ContainerPaths.cacheURL(forRelativePath: outputRel) else { continue }
            try? FileManager.default.removeItem(at: outputURL)

            let request = CadenceRenderRequest(
                sourceURL: job.sourceURL, cutPoints: job.cutPoints, titles: job.titles,
                preset: tier, outputURL: outputURL)

            do {
                // Heavy decode/analyze/render off the actor; only Sendable values cross back.
                let result = try await Task.detached(priority: .utility) {
                    try CadenceRenderer().render(request)
                }.value

                Self.upsertRendition(ctx, bookID: bookID, relPath: job.relPath,
                                     fingerprint: job.fingerprint, tier: tier.rawValue,
                                     trimmedRelPath: outputRel, result: result)
                try? ctx.save()
                // WP6: evict LRU renditions if total on-disk bytes exceeds the cap.
                CadenceCache.evictIfNeeded(context: ctx)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: outputURL)
                break
            } catch let ioErr as AudioIOError {
                // WP10: DRM-protected or undecodable file — mark the book permanently unavailable
                // so future enqueues are no-ops. Playback always falls back to the original.
                try? FileManager.default.removeItem(at: outputURL)
                switch ioErr {
                case .noAudioTrack, .undecodable:
                    // Re-fetch the book into this context (the `book` reference above may be stale).
                    if let b = (try? ctx.fetch(FetchDescriptor<Audiobook>()))?.first(where: { $0.id == bookID }) {
                        b.cadenceUnavailable = true
                        try? ctx.save()
                    }
                    return  // stop processing all remaining jobs for this book
                default:
                    break   // other AudioIOError (tooLong, allocationFailed, etc.) — non-permanent, skip job
                }
            } catch {
                // Other render failure: remove partial output; playback falls back to the original.
                try? FileManager.default.removeItem(at: outputURL)
            }
        }
    }

    // MARK: - Job building (pure)

    /// One render job per **distinct source file**. M4B (all tracks share one file) → a single job
    /// whose cut points are the chapter prefix-sums; MP3 folder → one job per file (one chunk).
    struct Job {
        let relPath: String
        let sourceURL: URL
        let cutPoints: [TimeInterval]
        let titles: [String]
        let fingerprint: String
    }

    static func buildJobs(for book: Audiobook) -> [Job] {
        // Group ordered tracks by file, preserving first-seen order.
        var order: [String] = []
        var byFile: [String: [AudiobookTrack]] = [:]
        for t in book.orderedTracks {
            if byFile[t.fileRelPath] == nil { order.append(t.fileRelPath) }
            byFile[t.fileRelPath, default: []].append(t)
        }

        var jobs: [Job] = []
        for relPath in order {
            guard let tracks = byFile[relPath],
                  let sourceURL = try? ContainerPaths.url(forRelativePath: relPath),
                  // WP10: never render partial downloads — guard the file physically exists.
                  FileManager.default.fileExists(atPath: sourceURL.path),
                  let fingerprint = CadenceFingerprint.of(fileAt: sourceURL) else { continue }
            // Chapter start offsets within this file = running prefix sums of durations.
            var cutPoints: [TimeInterval] = []
            var acc: TimeInterval = 0
            for t in tracks { cutPoints.append(acc); acc += t.duration }
            jobs.append(Job(relPath: relPath, sourceURL: sourceURL,
                            cutPoints: cutPoints, titles: tracks.map(\.title), fingerprint: fingerprint))
        }
        return jobs
    }

    /// Deterministic cache filename per (book, file, tier, versions) so a re-render overwrites and
    /// stale-tier/version files are orphaned (WP6 LRU reclaims them).
    static func outputRelPath(bookID: UUID, relPath: String, tier: CadenceSettings.Preset) -> String {
        "\(bookID.uuidString)-\(fnv1a(relPath))-\(tier.rawValue)-a\(CadenceVersions.analyzer)-r\(CadenceVersions.renderer).m4a"
    }

    /// Stable (non-randomized, unlike `Hasher`) 64-bit FNV-1a hex — safe, short filename token.
    static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }

    // MARK: - SwiftData helpers (run on the actor's context)

    static func existingRendition(_ ctx: ModelContext, bookID: UUID, relPath: String) -> TrimmedRendition? {
        (try? ctx.fetch(FetchDescriptor<TrimmedRendition>()))?
            .first { $0.bookID == bookID && $0.sourceFileRelPath == relPath }
    }

    static func upsertRendition(_ ctx: ModelContext, bookID: UUID, relPath: String,
                                fingerprint: String, tier: String, trimmedRelPath: String,
                                result: CadenceRenderResult) {
        // Replace any prior row for this file (stale key/version/tier).
        let stale = (try? ctx.fetch(FetchDescriptor<TrimmedRendition>()))?
            .filter { $0.bookID == bookID && $0.sourceFileRelPath == relPath } ?? []
        for row in stale { ctx.delete(row) }

        let timelineBlob = (try? JSONEncoder().encode(result.timelineMap)) ?? Data()
        let chapterBlob = (try? JSONEncoder().encode(result.chapters)) ?? Data()
        ctx.insert(TrimmedRendition(
            bookID: bookID, sourceFileRelPath: relPath, tier: tier,
            contentFingerprint: fingerprint,
            analyzerVersion: CadenceVersions.analyzer, rendererVersion: CadenceVersions.renderer,
            trimmedRelPath: trimmedRelPath,
            originalDuration: result.originalDuration, trimmedDuration: result.trimmedDuration,
            savedSeconds: result.savedSeconds,
            timelineMapBlob: timelineBlob, chapterMapBlob: chapterBlob))
    }
}
