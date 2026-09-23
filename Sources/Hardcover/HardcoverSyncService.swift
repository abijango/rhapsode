import Foundation
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

/// Pushes audiobook listening progress to hardcover.app.
///
/// Deliberately NOT a `ProgressSync` conformer. That protocol is symmetric last-writer-wins for
/// "the same position across *my* devices"; Hardcover is one-way outbound, keyed to a remote
/// edition, and its numbers live in a different domain (edition seconds, not local track/offset).
/// Conforming would make `pullAll()` hand Hardcover-domain positions to `SyncManager`'s merge and
/// fight the Dropbox/SMB position sync.
@MainActor
@Observable
final class HardcoverSyncService {
    private let client: HardcoverClient
    private var context: ModelContext?

    /// Status surfaced in Settings.
    private(set) var lastError: String?
    private(set) var lastSuccessAt: Date?
    private(set) var isBusy = false
    /// Books matched but awaiting the user's confirmation.
    private(set) var pendingReviewCount = 0

    /// Coalesces the bursts of `pause()` that interruptions and route changes produce.
    private var inFlight: [UUID: Task<Void, Never>] = [:]
    /// What each in-flight task intends to send, so `flushNow()` can send it immediately
    /// instead of waiting out the coalesce window.
    private var pending: [UUID: (book: Audiobook, editionId: Int, seconds: Int)] = [:]

    /// Books that crossed the finish line and should be offered the rating sheet.
    var finishCandidate: Audiobook?
    /// One automatic matching pass per launch — it costs two API calls per unmatched book.
    private var didAutoMatchThisLaunch = false

    /// Don't re-push unless the listener actually moved this far. One minute of book time is
    /// below the resolution anyone perceives on a progress bar, and it keeps a fidgety
    /// pause/resume session from spending the rate limit.
    private static let minimumDeltaSeconds = 60
    /// Bursts of pause() within this window collapse into one push. Kept short: in practice
    /// people pause and put the phone away within a couple of seconds, and every second here
    /// is a second the push can be lost to suspension.
    private static let coalesceWindow: TimeInterval = 1.5

    init(client: HardcoverClient = HardcoverClient()) {
        self.client = client
    }

    func attach(context: ModelContext) { self.context = context }

    // MARK: - Account

    /// Confirm a pasted token and return the username it belongs to.
    @discardableResult
    func verifyToken() async throws -> String {
        struct Me: Decodable { let me: [Row]; struct Row: Decodable { let id: Int; let username: String? } }
        let response: Me = try await client.run("{ me { id username } }")
        guard let username = response.me.first?.username else {
            throw HardcoverError.decoding("no user on token")
        }
        HardcoverSettings.username = username
        lastError = nil
        lastSuccessAt = Date()
        // Connecting should be enough to get the library matched; don't make them find a button.
        didAutoMatchThisLaunch = false
        return username
    }

    // MARK: - Matching

    /// Rank editions for a book without changing anything.
    func candidates(for book: Audiobook, query: String? = nil) async throws -> [HardcoverCandidate] {
        // Snapshot the fields on the main actor; the model itself must not cross into the client.
        let local = HardcoverMatcher.LocalBook(book)
        return try await HardcoverMatcher.candidates(for: local, client: client, overrideQuery: query)
    }

    /// Record a chosen edition on the book. Writes nothing to Hardcover — the library row is
    /// created lazily on the first real push, which is what keeps connecting the account from
    /// flooding the user's public activity feed.
    func apply(_ candidate: HardcoverCandidate, to book: Audiobook, state: HardcoverMatchState) {
        book.hardcoverBookId = candidate.edition.bookId
        book.hardcoverEditionId = candidate.edition.id
        book.hardcoverEditionSeconds = candidate.edition.audioSeconds
        book.hardcoverSlug = candidate.edition.bookSlug
        book.hardcoverState = state
        // A different edition invalidates the cached library rows.
        book.hardcoverUserBookId = nil
        book.hardcoverUserBookReadId = nil
        book.hardcoverLastPushedSeconds = nil
        try? context?.save()
    }

    /// "Not on Hardcover" — sticky, so the background matcher stops proposing it.
    func skip(_ book: Audiobook) {
        book.clearHardcoverMatch()
        book.hardcoverState = .skipped
        try? context?.save()
    }

    func unmatch(_ book: Audiobook) {
        book.clearHardcoverMatch()
        try? context?.save()
    }

    /// Background pass run once per launch. Without this, a book only ever gets matched if the
    /// user opens Settings and taps "Find matches now" — so a newly imported book silently
    /// never syncs, with nothing on screen saying why.
    func matchLibraryIfNeeded(_ books: [Audiobook]) async {
        guard HardcoverSettings.isActive, !didAutoMatchThisLaunch, !isBusy else { return }
        let needsMatching = books.contains {
            $0.hardcoverEditionId == nil && $0.hardcoverState != .skipped
        }
        guard needsMatching else { return }
        didAutoMatchThisLaunch = true
        await matchLibrary(books)
    }

    /// Resolve editions across the library, auto-applying only the near-exact ones. Everything
    /// ambiguous is left `unmatched` and counted in `pendingReviewCount` for the user to review.
    func matchLibrary(_ books: [Audiobook]) async {
        guard HardcoverSettings.isActive else { return }
        isBusy = true
        defer { isBusy = false }
        var pending = 0
        for book in books where book.hardcoverEditionId == nil && book.hardcoverState != .skipped {
            do {
                let ranked = try await candidates(for: book)
                if let exact = HardcoverMatcher.autoApplicable(ranked) {
                    apply(exact, to: book, state: .auto)
                    log(book, "auto-matched edition \(exact.edition.id) — \(exact.evidence)")
                } else if ranked.isEmpty {
                    log(book, "no audiobook editions found (searched "
                              + "\"\(HardcoverMatcher.searchTerm(title: book.title, author: book.author))\")")
                } else {
                    pending += 1
                    // The top few with their deltas: this is what shows whether the right
                    // edition is missing entirely or merely wasn't confident enough.
                    let summary = ranked.prefix(3).map {
                        "\($0.edition.id):\($0.durationDelta.map { d in "\(d)s" } ?? "no runtime")"
                            + ($0.authorMatches ? "" : " (author mismatch)")
                    }.joined(separator: ", ")
                    log(book, "needs review — local \(Int(book.totalDuration))s, top: \(summary)")
                }
            } catch {
                record(error, book: book)
                if (error as? HardcoverError)?.isTransient == true { break }
            }
        }
        pendingReviewCount = pending
    }

    // MARK: - Progress push

    /// Entry point wired to `AudiobookPlayer.onPlaybackStopped`. Fires on pause and stop only —
    /// never on ticks or seeks.
    func playbackStopped(_ book: Audiobook, progress: Double, endedNaturally: Bool,
                         isBookSwitch: Bool = false) {
        // Every early return here used to be silent, which made "this book just doesn't sync"
        // impossible to diagnose from the outside. Name the reason instead.
        guard HardcoverSettings.isActive else {
            log(book, "skip — Hardcover not connected")
            return
        }
        guard book.hardcoverState.syncs else {
            log(book, "skip — not matched (state=\(book.hardcoverState.rawValue))")
            return
        }
        guard let editionId = book.hardcoverEditionId else {
            log(book, "skip — matched but no edition id")
            return
        }

        let finished = progress >= HardcoverSettings.finishThreshold || endedNaturally
        let seconds = editionSeconds(for: book, progress: progress)

        // Skip a push that wouldn't move the needle — UNLESS the book just finished. People
        // routinely finish in a final session shorter than the threshold, and swallowing that
        // push would mean the Read status and the rating prompt could never fire.
        if !finished, let last = book.hardcoverLastPushedSeconds,
           abs(seconds - last) < Self.minimumDeltaSeconds {
            log(book, "skip — moved only \(abs(seconds - last))s since last push "
                      + "(now \(seconds)s, last \(last)s; needs \(Self.minimumDeltaSeconds)s)")
            return
        }

        log(book, "queue push \(seconds)s (edition \(editionId), progress "
                  + String(format: "%.3f", progress) + (finished ? ", finished" : "") + ")")

        // Offer the rating sheet — but not for a book already closed out. `markFinished` pushes
        // the edition's full runtime, so "we've already reported this as complete" is exactly
        // the condition that means don't ask again.
        let alreadyFinished = (book.hardcoverLastPushedSeconds ?? 0) >= (book.hardcoverEditionSeconds ?? .max)
        // ...and not when the user simply opened a different book: `teardown()` also reports a
        // stop, and popping "Mark <previous book> as Read?" over the book they just tapped is
        // the wrong moment for the question.
        if finished, !alreadyFinished, !isBookSwitch, HardcoverSettings.finishPromptEnabled {
            finishCandidate = book
        }

        let id = book.id
        inFlight[id]?.cancel()
        pending[id] = (book, editionId, seconds)

        // Hold a background assertion across the whole coalesce-then-push. Pausing and
        // immediately locking the phone is the NORMAL way a listening session ends — without
        // this the app suspends mid-wait and the push is simply lost, silently.
        let assertion = BackgroundAssertion("hardcover-push")
        let task = Task { [weak self] in
            defer { assertion.end() }
            // Coalesce: an interruption can fire pause() several times in a second.
            try? await Task.sleep(for: .seconds(Self.coalesceWindow))
            guard !Task.isCancelled, let self else { return }
            await self.sendPending(id)
        }
        inFlight[id] = task
        Task { [weak self] in
            _ = await task.value
            // Only clear the slot if it's still ours — a later pause may have replaced it.
            guard let self, self.inFlight[id] == task else { return }
            self.inFlight[id] = nil
        }
    }

    /// Send whatever is queued for `id`, if anything still is.
    private func sendPending(_ id: UUID) async {
        guard let queued = pending.removeValue(forKey: id) else { return }
        await push(queued.book, editionId: queued.editionId, seconds: queued.seconds)
    }

    /// Send every queued push right now without waiting out the coalesce window. Called when
    /// the app is about to be suspended — the moment a pending push would otherwise be lost.
    func flushNow() async {
        guard !pending.isEmpty else { return }
        let ids = Array(pending.keys)
        for id in ids { inFlight[id]?.cancel() }
        let assertion = BackgroundAssertion("hardcover-flush")
        defer { assertion.end() }
        for id in ids { await sendPending(id) }
    }

    /// Source-domain fraction scaled into the matched edition's runtime.
    ///
    /// Three ways to get this wrong, all silent: using output-domain time (SmartSpeech trims
    /// silence, so wall-clock listening is shorter than book time), using `listenedSeconds`
    /// (a lifetime cumulative stat that exceeds the book length), or sending the local file's
    /// raw seconds (the edition's runtime differs, so the position drifts).
    private func editionSeconds(for book: Audiobook, progress: Double) -> Int {
        Self.editionSeconds(progress: progress,
                            editionRuntime: book.hardcoverEditionSeconds,
                            localDuration: book.totalDuration)
    }

    /// Pure form, so the scaling can be tested without a model or a network. `nonisolated`
    /// because it touches no state — it's arithmetic, not player interaction.
    nonisolated static func editionSeconds(progress: Double, editionRuntime: Int?, localDuration: Double) -> Int {
        let clamped = min(max(progress.isFinite ? progress : 0, 0), 1)
        guard let runtime = editionRuntime, runtime > 0 else {
            return Int((clamped * max(0, localDuration)).rounded())
        }
        return Int((clamped * Double(runtime)).rounded())
    }

    private func push(_ book: Audiobook, editionId: Int, seconds: Int) async {
        var step = "resolve"
        do {
            let link = try await resolveLink(book, editionId: editionId)
            step = "update_user_book_read"
            // The row we ended up writing to — not necessarily the one we started with, since
            // the retry below resolves a fresh one. Verification has to check the row that
            // actually took the write.
            var writtenReadId = link.userBookReadId
            do {
                try await updateRead(writtenReadId, editionId: editionId, seconds: seconds)
            } catch {
                // The read row can vanish if the user edits the book on the website. Re-resolve
                // once — a fresh read-through gets a new id — before giving up.
                guard !(error is CancellationError) else { return }
                // ...but ONLY when the row is what's wrong. A malformed request fails no matter
                // which row it targets, and re-resolving it mints a new read-through per
                // attempt — polluting the user's reading history with empty reads.
                guard (error as? HardcoverError)?.indicatesMissingRow == true else { throw error }
                log(book, "read row \(writtenReadId) rejected — re-resolving")
                book.hardcoverUserBookReadId = nil
                let retry = try await resolveLink(book, editionId: editionId)
                writtenReadId = retry.userBookReadId
                try await updateRead(writtenReadId, editionId: editionId, seconds: seconds)
            }
            book.hardcoverLastPushedSeconds = seconds
            book.hardcoverLastPushedAt = Date()
            try? context?.save()
            lastError = nil
            lastSuccessAt = Date()
            log(book, "pushed \(seconds)s OK")
            await verify(book, readId: writtenReadId, expected: seconds)
        } catch {
            record(error, book: book, step: step)
        }
    }

    /// Forget the recorded high-water mark so the delta gate can't suppress a retry of a
    /// position that never actually landed.
    private func invalidateLastPush(_ book: Audiobook) {
        book.hardcoverLastPushedSeconds = nil
        try? context?.save()
    }

    /// Send the current position immediately, ignoring the movement gate.
    ///
    /// Needed because the gate is measured against what we BELIEVE we last sent. If that
    /// belief is wrong — a push recorded as successful that never landed — the gate quietly
    /// blocks every retry from the same spot. This is the way out, and the way to test
    /// without having to listen for a full minute.
    func pushNow(_ book: Audiobook, progress: Double) async {
        guard HardcoverSettings.isActive, book.hardcoverState.syncs,
              let editionId = book.hardcoverEditionId else {
            log(book, "sync now — nothing to do (not connected or not matched)")
            return
        }
        isBusy = true
        defer { isBusy = false }
        invalidateLastPush(book)
        // Re-resolve from scratch: this is the repair action, so the cached user_book /
        // read-through ids are exactly what it must not take on trust.
        book.hardcoverUserBookReadId = nil
        try? context?.save()
        let seconds = editionSeconds(for: book, progress: progress)
        log(book, "sync now — forcing \(seconds)s")
        await push(book, editionId: editionId, seconds: seconds)
    }

    /// Read the row back and log what Hardcover actually stored.
    ///
    /// Worth the extra query: a mutation that returns 200 with no error is NOT proof the value
    /// landed where the website reads it from. This turns "pushed OK" into something checkable
    /// without having to open a browser.
    private func verify(_ book: Audiobook, readId: Int, expected: Int) async {
        struct Response: Decodable {
            let user_book_reads: [Row]
            struct Row: Decodable {
                let id: Int
                let progress_seconds: Int?
                let edition_id: Int?
                let finished_at: String?
                let user_book: UserBook?
                struct UserBook: Decodable { let id: Int; let status_id: Int?; let edition_id: Int? }
            }
        }
        let query = """
        query RhapsodeVerify($id: Int!) {
          user_book_reads(where: { id: { _eq: $id } }) {
            id
            progress_seconds
            edition_id
            finished_at
            user_book { id status_id edition_id }
          }
        }
        """
        do {
            let response: Response = try await client.run(query, variables: ["id": readId])
            guard let row = response.user_book_reads.first else {
                log(book, "VERIFY read row \(readId) does not exist — the cached id is stale")
                invalidateLastPush(book)
                return
            }
            let stored = row.progress_seconds.map(String.init) ?? "nil"
            let matches = row.progress_seconds == expected
            if !matches { invalidateLastPush(book) }
            // The read may have been closed on the website since we cached it. Release it so
            // the next session starts a new read-through rather than reopening a finished one.
            if row.finished_at != nil {
                log(book, "read row \(row.id) is finished — releasing it; "
                          + "the next listen will start a new read-through")
                book.hardcoverUserBookReadId = nil
                try? context?.save()
            }
            log(book, "\(matches ? "verified" : "VERIFY MISMATCH") stored=\(stored)s "
                      + "expected=\(expected)s readEdition=\(row.edition_id.map(String.init) ?? "nil") "
                      + "userBookEdition=\(row.user_book?.edition_id.map(String.init) ?? "nil") "
                      + "status=\(row.user_book?.status_id.map(String.init) ?? "nil")")
        } catch {
            log(book, "verify failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Hardcover row resolution

    /// Ensure the book has a `user_book` and an open `user_book_read`, creating them if needed.
    /// Cached on the model so this costs nothing after the first push.
    private func resolveLink(_ book: Audiobook, editionId: Int) async throws -> HardcoverLink {
        if let link = book.hardcoverLink { return link }
        guard let bookId = book.hardcoverBookId else {
            // Distinct from "not connected" — same symptom, completely different fix.
            throw HardcoverError.unresolvedBook(book.title)
        }

        // `me` rather than a stored user id — one less thing to keep in sync with the token.
        struct Response: Decodable {
            let me: [Row]
            struct Row: Decodable {
                let user_books: [UserBook]
                struct UserBook: Decodable {
                    let id: Int
                    let status_id: Int?
                    let edition_id: Int?
                    let user_book_reads: [Read]
                    struct Read: Decodable { let id: Int; let finished_at: String? }
                }
            }
        }
        let query = """
        query RhapsodeUserBook($bookId: Int!) {
          me {
            user_books(where: { book_id: { _eq: $bookId } }) {
              id
              status_id
              edition_id
              user_book_reads(order_by: { id: desc }) { id finished_at }
            }
          }
        }
        """
        let found: Response = try await client.run(query, variables: ["bookId": bookId])
        let existing = found.me.first?.user_books.first

        // Status 2 (Currently Reading) is a public feed event, so set it exactly once — when the
        // library row is first created or first seen in a pre-reading state. Never per pause.
        let userBookId: Int
        if let existing {
            userBookId = existing.id
            log(book, "found user_book \(existing.id) status=\(existing.status_id.map(String.init) ?? "nil") "
                      + "edition=\(existing.edition_id.map(String.init) ?? "nil")")
            if existing.status_id != 2 {
                // Includes status 3 (Read). Listening to a book you've already finished is a
                // re-listen, and Hardcover models that as Currently Reading plus a NEW
                // read-through. Leaving it at Read is why progress was stored but invisible.
                log(book, existing.status_id == 3
                          ? "was marked Read — moving back to Currently Reading for this re-listen"
                          : "setting status to Currently Reading")
                try await setStatus(userBookId, statusId: 2)
            }
            // The library row may already point at a DIFFERENT edition — commonly the ebook or
            // paperback, if the book was added to Hardcover before this integration existed.
            // Progress written against our audiobook edition then has nothing to attach to in
            // the UI, so repoint the row. Without this the push succeeds and shows nothing.
            if existing.edition_id != editionId {
                log(book, "repointing user_book \(userBookId) to audiobook edition \(editionId)")
                try await setEdition(userBookId, editionId: editionId)
            }
        } else {
            log(book, "creating Hardcover library entry for book \(bookId)")
            userBookId = try await insertUserBook(bookId: bookId, editionId: editionId, statusId: 2)
        }

        // Reuse the OPEN read-through only. A finished row (finished_at set) belongs to a
        // completed read; writing today's position into it corrupts that history and shows
        // nothing as in-progress.
        let readId: Int
        let rows = (existing?.user_book_reads ?? [])
            .map { HardcoverReadRow(id: $0.id, finishedAt: $0.finished_at) }
        switch HardcoverReadPlan.plan(for: rows) {
        case .reuse(let open):
            readId = open
        case .startNew:
            log(book, rows.isEmpty
                      ? "starting the first read-through on user_book \(userBookId)"
                      : "every previous read is finished — starting a NEW read-through "
                        + "(re-listen) on user_book \(userBookId)")
            readId = try await insertRead(userBookId: userBookId, editionId: editionId)
        }

        book.hardcoverUserBookId = userBookId
        book.hardcoverUserBookReadId = readId
        try? context?.save()
        return HardcoverLink(userBookId: userBookId, userBookReadId: readId)
    }

    // MARK: - Mutations
    //
    // These are custom Hasura *actions*, not generated CRUD: hand-written argument names and an
    // `error` STRING in the payload, so HTTP 200 does not mean the write landed. Shapes taken
    // from Hardcover's docs plus the query documents the audiobookshelf-hardcover-sync project
    // runs against this same API in production.

    private func insertUserBook(bookId: Int, editionId: Int, statusId: Int) async throws -> Int {
        struct Response: Decodable { let insert_user_book: HardcoverActionPayload? }
        let mutation = """
        mutation RhapsodeInsertUserBook($object: UserBookCreateInput!) {
          insert_user_book(object: $object) { id error }
        }
        """
        let response: Response = try await client.run(mutation, variables: [
            "object": ["book_id": bookId, "edition_id": editionId, "status_id": statusId]
        ])
        guard let payload = response.insert_user_book else {
            throw HardcoverError.action("Hardcover did not create the library entry.")
        }
        return try payload.requireId()
    }

    // NOTE: do NOT send `reading_format_id` on a read row. The API rejects it outright —
    // "field 'reading_format_id' not found in type: 'DatesReadInput'" — even though the
    // third-party client this integration's query shapes came from declares it in its struct.
    // It isn't needed either: Hardcover infers the format from the edition, and the site
    // already shows the audiobook icon for these reads.

    private func insertRead(userBookId: Int, editionId: Int) async throws -> Int {
        struct Response: Decodable { let insert_user_book_read: HardcoverActionPayload? }
        let mutation = """
        mutation RhapsodeInsertRead($userBookId: Int!, $read: DatesReadInput!) {
          insert_user_book_read(user_book_id: $userBookId, user_book_read: $read) { id error }
        }
        """
        let started = HardcoverDate.day(Date())
        let read: [String: Any] = [
            "edition_id": editionId, "started_at": started, "progress_seconds": 0,
        ]
        let response: Response = try await client.run(mutation, variables: [
            "userBookId": userBookId, "read": read,
        ])
        guard let payload = response.insert_user_book_read else {
            throw HardcoverError.action("Hardcover did not start a read-through.")
        }
        return try payload.requireId()
    }

    private func updateRead(_ readId: Int, editionId: Int, seconds: Int) async throws {
        struct Response: Decodable { let update_user_book_read: HardcoverActionPayload? }
        let mutation = """
        mutation RhapsodeUpdateRead($id: Int!, $object: DatesReadInput!) {
          update_user_book_read(id: $id, object: $object) { id error }
        }
        """
        let object: [String: Any] = ["edition_id": editionId, "progress_seconds": seconds]
        let response: Response = try await client.run(mutation, variables: [
            "id": readId, "object": object,
        ])
        guard let payload = response.update_user_book_read else {
            throw HardcoverError.action("Hardcover did not accept the progress update.")
        }
        // `requireId`, not `throwIfFailed`: a PATCH against a row that no longer exists (or
        // was never ours) comes back with no error AND no id. Accepting that as success is
        // what produces "pushed OK" in the log while nothing changes on the website.
        _ = try payload.requireId()
    }

    private func setEdition(_ userBookId: Int, editionId: Int) async throws {
        struct Response: Decodable { let update_user_book: HardcoverActionPayload? }
        let mutation = """
        mutation RhapsodeSetEdition($id: Int!, $editionId: Int!) {
          update_user_book(id: $id, object: { edition_id: $editionId }) { id error }
        }
        """
        let response: Response = try await client.run(mutation, variables: [
            "id": userBookId, "editionId": editionId
        ])
        try response.update_user_book?.throwIfFailed()
    }

    private func setStatus(_ userBookId: Int, statusId: Int) async throws {
        struct Response: Decodable { let update_user_book: HardcoverActionPayload? }
        let mutation = """
        mutation RhapsodeSetStatus($id: Int!, $statusId: Int!) {
          update_user_book(id: $id, object: { status_id: $statusId }) { id error }
        }
        """
        let response: Response = try await client.run(mutation, variables: [
            "id": userBookId, "statusId": statusId
        ])
        try response.update_user_book?.throwIfFailed()
    }

    // MARK: - Finish

    /// Mark the book Read with an optional rating. Only ever called from the finish sheet —
    /// status 3 is a public event and never happens behind the user's back.
    func markFinished(_ book: Audiobook, rating: Double?, review: String?) async {
        guard HardcoverSettings.isActive,
              let editionId = book.hardcoverEditionId,
              let bookId = book.hardcoverBookId else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let link = try await resolveLink(book, editionId: editionId)
            let today = HardcoverDate.day(Date())
            // Close out the read-through at full runtime so the finished book isn't left at 98%.
            let total = book.hardcoverEditionSeconds ?? Int(book.totalDuration.rounded())
            try await finishRead(link.userBookReadId, editionId: editionId,
                                 seconds: total, finishedAt: today)
            try await setStatus(link.userBookId, statusId: 3)
            await setRating(link.userBookId, rating: rating, review: review)
            book.hardcoverLastPushedSeconds = nil
            book.hardcoverLastPushedAt = Date()
            // Release the read-through we just closed. Listening again is a NEW read, and a
            // cached id pointing at a finished row would have us overwrite the read we just
            // completed instead of starting the next one.
            book.hardcoverUserBookReadId = nil
            try? context?.save()
            lastError = nil
            lastSuccessAt = Date()
            log(book, "marked Read (\(total)s) — next listen will start a new read-through")
            _ = bookId
        } catch {
            record(error)
        }
    }

    private func finishRead(_ readId: Int, editionId: Int, seconds: Int, finishedAt: String) async throws {
        struct Response: Decodable { let update_user_book_read: HardcoverActionPayload? }
        let mutation = """
        mutation RhapsodeFinishRead($id: Int!, $object: DatesReadInput!) {
          update_user_book_read(id: $id, object: $object) { id error }
        }
        """
        let response: Response = try await client.run(mutation, variables: [
            "id": readId,
            "object": ["edition_id": editionId, "progress_seconds": seconds,
                       "finished_at": finishedAt]
        ])
        try response.update_user_book_read?.throwIfFailed()
    }

    /// Rating and review go in a SEPARATE mutation from the status, deliberately.
    ///
    /// `setStatus` uses an inline object literal whose shape is confirmed. A named input type
    /// for rating/review is not: if that type name is wrong, GraphQL rejects the document at
    /// validation and takes the `status_id: 3` write down with it — the book would never be
    /// marked Read because we guessed a field name. Keeping them apart means the status
    /// always lands, and an unsupported rating degrades to "marked Read, rating not saved".
    private func setRating(_ userBookId: Int, rating: Double?, review: String?) async {
        let trimmedReview = review?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRating = (rating ?? 0) > 0
        let hasReview = !(trimmedReview ?? "").isEmpty
        guard hasRating || hasReview else { return }

        struct Response: Decodable { let update_user_book: HardcoverActionPayload? }
        var fields: [String] = []
        var variables: [String: Any] = ["id": userBookId]
        var declarations = ["$id: Int!"]
        if let rating, hasRating {
            declarations.append("$rating: numeric")
            variables["rating"] = rating
            fields.append("rating: $rating")
        }
        if let trimmedReview, hasReview {
            declarations.append("$review: String")
            variables["review"] = trimmedReview
            fields.append("review: $review")
        }
        let mutation = """
        mutation RhapsodeRate(\(declarations.joined(separator: ", "))) {
          update_user_book(id: $id, object: { \(fields.joined(separator: ", ")) }) { id error }
        }
        """
        do {
            let response: Response = try await client.run(mutation, variables: variables)
            try response.update_user_book?.throwIfFailed()
        } catch {
            // Non-fatal: the book is already marked Read, which is the part that matters.
            log(nil, "rating not saved — \(error.localizedDescription)")
        }
    }

    // MARK: - Status

    private func record(_ error: Error, book: Audiobook? = nil, step: String? = nil) {
        lastError = (error as? HardcoverError)?.errorDescription ?? error.localizedDescription
        // Naming the step matters: "insert_user_book failed" and "update_user_book_read
        // failed" look identical in the UI but mean completely different things.
        log(book, "ERROR\(step.map { " at \($0)" } ?? "") — \(lastError ?? "?")")
    }

    /// One place so every Hardcover line is greppable as `hardcover:` in Diagnostics.
    private func log(_ book: Audiobook?, _ message: String) {
        let prefix = book.map { "“\($0.title.prefix(40))” " } ?? ""
        DiagnosticLog.info("hardcover: \(prefix)\(message)", category: .sync)
    }
}

enum HardcoverDate {
    /// Hardcover's `started_at`/`finished_at` are plain `date` columns, not timestamps.
    /// Built per call rather than cached: `ISO8601DateFormatter` isn't `Sendable`, and a
    /// shared instance would be a data race under Swift 6 strict concurrency.
    static func day(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f.string(from: date)
    }
}


/// Keeps the app alive long enough to finish a network write started just before the user
/// locked the phone. iOS grants roughly 30 seconds, which is ample for one mutation.
@MainActor
final class BackgroundAssertion {
    #if canImport(UIKit)
    private var id: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(_ name: String) {
        #if canImport(UIKit)
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()   // expiry handler — must release or the app is killed
        }
        #endif
    }

    func end() {
        #if canImport(UIKit)
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
        #endif
    }
}
