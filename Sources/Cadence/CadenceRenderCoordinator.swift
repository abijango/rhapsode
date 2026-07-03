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
    /// True once `cancel` has cancelled the in-flight book's task. Lets a re-`enqueue` of that same
    /// book (the WP9 tier-change pattern: cancel → enqueue) queue a fresh render instead of being
    /// dropped by the "already current" guard — the current task is being torn down, so a new render
    /// IS wanted. Reset when the next book actually starts. Without this, a tier change issued while
    /// the previous render is still finishing (e.g. mid-upload) would never re-render.
    private var currentCancelled = false
    /// Render progress (0...1) for the book currently rendering, weighted by file duration.
    /// Read by the per-book settings sheet to draw a progress bar; cleared when the book finishes.
    private var progressByBook: [UUID: Double] = [:]

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
        // Queue unless it's already waiting, or already the current book (idempotent) — EXCEPT when
        // the current book was just cancelled (tier change), where a fresh render IS wanted.
        let isCurrentAndLive = currentBookID == bookID && !currentCancelled
        if !isCurrentAndLive && !queue.contains(bookID) { queue.append(bookID) }
        startNextIfIdle()
    }

    /// Enqueue every known audiobook. Idempotent: already-rendered files are cache-hits that skip
    /// re-render, so this self-heals a book that was imported before rendering existed.
    func enqueueAllBooks() {
        guard let container else { return }
        let ids = ((try? ModelContext(container).fetch(FetchDescriptor<Audiobook>())) ?? []).map(\.id)
        for id in ids { enqueue(bookID: id) }
    }

    /// Whether this book is currently rendering or waiting in the queue. Lets the per-book
    /// settings sheet show a live "Preparing…" instead of a dead-ended empty state.
    func isWorking(on bookID: UUID) -> Bool {
        currentBookID == bookID || queue.contains(bookID)
    }

    /// Current render progress (0...1) for a book, or nil if it isn't rendering. Drives the
    /// progress bar in the per-book settings sheet.
    func renderProgress(for bookID: UUID) -> Double? { progressByBook[bookID] }

    /// A live snapshot of what the coordinator is doing, for the render-status screen.
    struct RenderSnapshot: Sendable {
        /// Book currently rendering → progress 0...1.
        let activeProgress: [UUID: Double]
        /// Books waiting in the queue (not yet started).
        let queued: [UUID]
    }
    func snapshot() -> RenderSnapshot { RenderSnapshot(activeProgress: progressByBook, queued: queue) }

    /// Set from the render's progress callback (hopped onto the actor).
    private func setRenderProgress(_ bookID: UUID, _ value: Double) { progressByBook[bookID] = value }

    /// Cancel an in-flight or queued render (e.g. on tier change — WP9). The partial `.m4a` is
    /// discarded; a fresh `enqueue` re-renders from scratch (book-granularity resume).
    func cancel(bookID: UUID) {
        queue.removeAll { $0 == bookID }
        progressByBook[bookID] = nil
        if currentBookID == bookID { currentCancelled = true; activeTask?.cancel() }
    }

    // MARK: - Draining

    private func startNextIfIdle() {
        guard !isRunning, container != nil, !queue.isEmpty else { return }
        isRunning = true
        let bookID = queue.removeFirst()
        currentBookID = bookID
        currentCancelled = false
        activeTask = Task { [weak self] in
            await self?.process(bookID: bookID)
            await self?.finishCurrent()
        }
    }

    private func finishCurrent() {
        if let id = currentBookID { progressByBook[id] = nil }
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
        // Book-level progress is weighted by each file's duration; `completedDuration` advances as
        // files finish (or are skipped because already rendered).
        let totalDuration = jobs.reduce(0) { $0 + $1.duration }
        var completedDuration: TimeInterval = 0
        progressByBook[bookID] = 0

        for job in jobs {
            if Task.isCancelled { break }

            // Skip files already rendered for this exact key with the audio still present.
            if let existing = Self.existingRendition(ctx, bookID: bookID, relPath: job.relPath),
               existing.isValid(forFingerprint: job.fingerprint, tier: tier.rawValue),
               FileManager.default.fileExists(atPath: (try? ContainerPaths.cacheURL(forRelativePath: existing.trimmedRelPath))?.path ?? "") {
                existing.lastUsedAt = Date()
                try? ctx.save()
                completedDuration += job.duration
                progressByBook[bookID] = totalDuration > 0 ? completedDuration / totalDuration : 1
                continue
            }

            let outputRel = Self.outputRelPath(bookID: bookID, relPath: job.relPath, tier: tier)
            guard let outputURL = try? ContainerPaths.cacheURL(forRelativePath: outputRel) else { continue }
            try? FileManager.default.removeItem(at: outputURL)

            let request = CadenceRenderRequest(
                sourceURL: job.sourceURL, cutPoints: job.cutPoints, titles: job.titles,
                preset: tier, outputURL: outputURL)

            // Hop per-chunk file progress back onto the actor, weighted into book progress.
            let base = completedDuration
            let jobDuration = job.duration
            let onProgress: @Sendable (Double) -> Void = { [weak self] fileFraction in
                guard let self else { return }
                let value = totalDuration > 0 ? (base + fileFraction * jobDuration) / totalDuration : 0
                Task { await self.setRenderProgress(bookID, min(1, value)) }
            }

            let renderStart = Date()
            do {
                // Heavy decode/analyze/render off the actor; only Sendable values cross back.
                // `.userInitiated` (not `.utility`) so it runs on the performance cores rather than
                // being pinned to the efficiency cores — the user is usually waiting on the
                // "Preparing…" bar. Trades some battery/contention for a much faster prepare.
                let result = try await Task.detached(priority: .userInitiated) {
                    try CadenceRenderer().render(request, onProgress: onProgress)
                }.value

                // Record how long this file took: the lifetime counter + the per-file duration
                // shown on the render-status screen.
                let elapsed = Date().timeIntervalSince(renderStart)
                CadenceStats.addRender(elapsed)
                Self.upsertRendition(ctx, bookID: bookID, relPath: job.relPath,
                                     fingerprint: job.fingerprint, tier: tier.rawValue,
                                     trimmedRelPath: outputRel, result: result, renderDuration: elapsed)
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
            completedDuration += jobDuration
            progressByBook[bookID] = totalDuration > 0 ? completedDuration / totalDuration : 1
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
        /// Total source duration of this file (sum of its tracks) — weights book-level progress.
        let duration: TimeInterval
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
                            cutPoints: cutPoints, titles: tracks.map(\.title),
                            fingerprint: fingerprint, duration: acc))
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
                                fingerprint: String, tier: String,
                                trimmedRelPath: String,
                                result: CadenceRenderResult, renderDuration: TimeInterval) {
        // Replace any prior row for this file (stale key/version/tier).
        let stale = (try? ctx.fetch(FetchDescriptor<TrimmedRendition>()))?
            .filter { $0.bookID == bookID && $0.sourceFileRelPath == relPath } ?? []
        for row in stale { ctx.delete(row) }

        let timelineBlob = (try? JSONEncoder().encode(result.timelineMap)) ?? Data()
        let chapterBlob = (try? JSONEncoder().encode(result.chapters)) ?? Data()
        let projectedBlob = try? JSONEncoder().encode(result.projectedSavedByTier)
        ctx.insert(TrimmedRendition(
            bookID: bookID, sourceFileRelPath: relPath, tier: tier,
            contentFingerprint: fingerprint,
            analyzerVersion: CadenceVersions.analyzer, rendererVersion: CadenceVersions.renderer,
            trimmedRelPath: trimmedRelPath,
            originalDuration: result.originalDuration, trimmedDuration: result.trimmedDuration,
            savedSeconds: result.savedSeconds,
            projectedSavedByTierBlob: projectedBlob,
            timelineMapBlob: timelineBlob, chapterMapBlob: chapterBlob,
            renderDurationSeconds: renderDuration))
    }
}
