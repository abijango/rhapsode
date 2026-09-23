import Foundation

// MARK: - Match state

/// How a local audiobook relates to the Hardcover catalogue.
enum HardcoverMatchState: String {
    /// Never looked at, or looked at and nothing conclusive found.
    case unmatched
    /// Auto-applied because the edition runtime is effectively a fingerprint match.
    case auto
    /// The user picked this edition in the match sheet.
    case manual
    /// The user said "not on Hardcover" — sticky, never auto-matched again.
    case skipped

    init(stored: String?) { self = HardcoverMatchState(rawValue: stored ?? "") ?? .unmatched }

    /// Whether progress should be pushed for a book in this state.
    var syncs: Bool { self == .auto || self == .manual }
}

// MARK: - Catalogue DTOs

/// A candidate audiobook edition, with everything the match sheet needs to justify itself.
struct HardcoverEdition: Identifiable, Hashable, Sendable {
    let id: Int
    let bookId: Int
    let bookSlug: String?
    let bookTitle: String
    let editionTitle: String?
    /// Runtime of this edition. The whole basis of matching — nil means it isn't an audiobook.
    let audioSeconds: Int?
    let asin: String?
    let isbn13: String?
    let format: String?
    let coverURL: String?
    /// Everyone credited on this edition, flattened for display and author matching.
    let contributors: [String]
    /// Just the narrators, where Hardcover records the role. Empty is common and fine —
    /// narrator is only ever a tiebreak, never a requirement.
    var narrators: [String] = []

    var narratorLine: String? {
        let shown = narrators.isEmpty ? contributors : narrators
        return shown.isEmpty ? nil : shown.joined(separator: ", ")
    }

    /// Public page for this exact edition.
    var webURL: URL? {
        guard let bookSlug else { return URL(string: "https://hardcover.app/editions/\(id)") }
        return URL(string: "https://hardcover.app/books/\(bookSlug)/editions/\(id)")
    }
}

/// An edition paired with how well it fits the local file.
struct HardcoverCandidate: Identifiable, Hashable, Sendable {
    let edition: HardcoverEdition
    /// Signed difference (edition − local) in seconds; nil when the edition has no runtime.
    let durationDelta: Int?
    let authorMatches: Bool
    /// True only when the edition lists contributors and NONE of them is our author. Distinct
    /// from `!authorMatches`, which is also true when Hardcover simply has no contributor data
    /// — treating those the same would let missing metadata silently disable auto-matching.
    let authorConflicts: Bool
    let score: Double

    var id: Int { edition.id }

    /// Near-exact: the runtime is within half a minute and nothing contradicts it. The search
    /// that produced these candidates was already constrained by title and author, so runtime
    /// is picking between editions of a book we've established — a positive author match is
    /// corroboration, not a precondition.
    var isNearExact: Bool {
        guard let d = durationDelta else { return false }
        return abs(d) <= HardcoverMatcher.nearExactToleranceSeconds && !authorConflicts
    }

    /// Human-readable evidence for the match sheet, e.g. "11h 8m · matches your file (±4s)".
    var evidence: String {
        guard let seconds = edition.audioSeconds else { return "No runtime listed" }
        let runtime = Self.durationLabel(seconds)
        guard let delta = durationDelta else { return runtime }
        let magnitude = abs(delta)
        if magnitude <= HardcoverMatcher.nearExactToleranceSeconds {
            return "\(runtime) · matches your file (±\(magnitude)s)"
        }
        let sign = delta > 0 ? "longer" : "shorter"
        return "\(runtime) · \(Self.durationLabel(magnitude)) \(sign) than your file"
    }

    static func durationLabel(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "\(seconds)s"
    }
}

// MARK: - Library linkage

/// The Hardcover-side row ids for one local book. Resolved once at match time and cached on
/// the model, because the write chain is `user_book` → `user_book_read` → PATCH by row id.
struct HardcoverLink: Sendable, Equatable {
    var userBookId: Int
    var userBookReadId: Int
}

// MARK: - Errors

enum HardcoverError: LocalizedError {
    case notConfigured
    /// Matched to an edition but the parent book id is missing — re-match to repair.
    case unresolvedBook(String)
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    /// Hardcover's custom actions return 200 with an `error` field in the payload, so a
    /// successful HTTP response is not a successful mutation.
    case action(String)
    case graphQL([String])
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:      "Hardcover isn't connected."
        case .unresolvedBook(let t): "\(t) is matched to an edition but not to a book. "
                                     + "Re-match it from the shelf to repair."
        case .unauthorized:       "Hardcover rejected the API token. Create a new one and paste it again."
        case .rateLimited(let r): r.map { "Hardcover rate limit reached. Retrying in \(Int($0))s." }
                                    ?? "Hardcover rate limit reached."
        case .server(let s):      "Hardcover returned HTTP \(s)."
        case .action(let m):      m
        case .graphQL(let m):     m.first ?? "Hardcover rejected the request."
        case .decoding(let m):    "Unexpected response from Hardcover: \(m)"
        }
    }

    /// Whether this failure plausibly means "that row isn't there any more".
    ///
    /// Only Hardcover's own action-level errors qualify. A GraphQL validation error means the
    /// REQUEST is malformed — re-resolving and retrying it cannot help, and doing so creates a
    /// fresh read-through on the user's account for every attempt. That's how a bad field name
    /// silently littered a real library with empty reads.
    var indicatesMissingRow: Bool {
        if case .action = self { return true }
        return false
    }

    /// Whether retrying the same request later could plausibly succeed.
    var isTransient: Bool {
        switch self {
        case .rateLimited:        true
        case .server(let s):      s >= 500 || s == 408
        default:                  false
        }
    }
}


// MARK: - Re-read decisions

/// One Hardcover read-through, reduced to what the re-read decision actually depends on.
struct HardcoverReadRow: Equatable, Sendable {
    let id: Int
    /// Non-nil once the read is completed.
    let finishedAt: String?

    var isOpen: Bool { finishedAt == nil }
}

/// Which read-through a new listening session belongs to.
enum HardcoverReadPlan: Equatable, Sendable {
    /// Continue an in-progress read.
    case reuse(Int)
    /// Start a fresh read-through — the book has been finished before, so this is a re-read
    /// and Hardcover records it as a separate entry rather than overwriting the old one.
    case startNew

    /// Reading a book you've already finished must not overwrite that finished read: its dates
    /// and its place in your history belong to the first time through. The only row we may
    /// continue is one still open.
    static func plan(for reads: [HardcoverReadRow]) -> HardcoverReadPlan {
        // Highest id first — the most recent read, if several are somehow open.
        if let open = reads.filter(\.isOpen).max(by: { $0.id < $1.id }) {
            return .reuse(open.id)
        }
        return .startNew
    }
}
