import Foundation

/// Finds the Hardcover *audiobook edition* that corresponds to a local file.
///
/// The hard part isn't finding the book — it's picking the right edition. A popular title has
/// dozens (paperback, hardcover, ebook, several audiobook recordings with different narrators),
/// all sharing a title, author and often cover art. The one field that actually separates them
/// is **runtime**: we know the local file's duration exactly, and Hardcover publishes
/// `editions.audio_seconds`. So duration proximity dominates the score, and everything else
/// only breaks ties.
enum HardcoverMatcher {
    /// Within this much, two runtimes are the same recording. Different masterings of the same
    /// audiobook vary by a few seconds; different recordings vary by many minutes.
    static let nearExactToleranceSeconds = 30

    // MARK: Queries

    /// Typesense-backed catalogue search. `results` is an opaque JSON scalar (not a selectable
    /// GraphQL object), so it has to be decoded loosely.
    private static let searchQuery = """
    query RhapsodeSearch($q: String!) {
      search(query: $q, query_type: "Book", per_page: 8, page: 1) { results }
    }
    """

    /// Audiobook editions for the candidate books. Filtering on `audio_seconds` being non-null
    /// rather than a `reading_format_id` enum: the enum's numbering isn't documented, whereas
    /// "has a runtime" is exactly what makes an edition an audiobook for our purposes.
    private static let editionsQuery = """
    query RhapsodeEditions($ids: [Int!]!) {
      editions(
        where: { book_id: { _in: $ids }, audio_seconds: { _is_null: false } }
        order_by: { users_count: desc }
        limit: 60
      ) {
        id
        book_id
        title
        audio_seconds
        asin
        isbn_13
        edition_format
        contributions { contribution author { name } }
        cached_contributors
        image { url }
        book { id slug title contributions { author { name } } }
      }
    }
    """

    /// Fallback with no contributor selections. Runtime alone is still a usable signal, and
    /// `authorConflicts` is simply false everywhere, so near-exact matches keep working.
    private static let editionsQueryMinimal = """
    query RhapsodeEditionsMinimal($ids: [Int!]!) {
      editions(
        where: { book_id: { _in: $ids }, audio_seconds: { _is_null: false } }
        order_by: { users_count: desc }
        limit: 60
      ) {
        id
        book_id
        title
        audio_seconds
        asin
        isbn_13
        edition_format
        image { url }
        book { id slug title }
      }
    }
    """

    // MARK: Entry point

    /// Everything the matcher needs about a local file. Plain values rather than the
    /// `Audiobook` model: a SwiftData object isn't `Sendable` and must not cross into the
    /// client actor, and taking only these four fields keeps the matcher trivially testable.
    struct LocalBook: Sendable {
        let title: String
        let author: String?
        let narrator: String?
        let durationSeconds: Double

        init(_ book: Audiobook) {
            title = book.title
            author = book.author
            narrator = book.narrator
            durationSeconds = book.totalDuration
        }
    }

    /// Rank audiobook editions for a local file, best first.
    static func candidates(for local: LocalBook,
                           client: HardcoverClient,
                           overrideQuery: String? = nil) async throws -> [HardcoverCandidate] {
        let term = overrideQuery ?? searchTerm(title: local.title, author: local.author)
        guard !term.isEmpty else { return [] }

        let search: SearchEnvelope = try await client.run(searchQuery, variables: ["q": term])
        let bookIds = search.bookIds
        guard !bookIds.isEmpty else { return [] }

        let editions: EditionsEnvelope
        do {
            editions = try await client.run(editionsQuery, variables: ["ids": bookIds])
        } catch let error as HardcoverError where !error.isTransient {
            // Don't let one unavailable field disable matching for the whole library.
            DiagnosticLog.info("hardcover: editions query fell back to minimal — \(error)",
                               category: .sync)
            editions = try await client.run(editionsQueryMinimal, variables: ["ids": bookIds])
        }
        return rank(editions.editions.map(\.model),
                    localDuration: local.durationSeconds,
                    author: local.author,
                    narrator: local.narrator)
    }

    /// Pure ranking step, split out so it can be unit-tested against recorded fixtures without
    /// touching the network.
    static func rank(_ editions: [HardcoverEdition],
                     localDuration: Double,
                     author: String?,
                     narrator: String?) -> [HardcoverCandidate] {
        let localSeconds = Int(localDuration.rounded())
        let wantedAuthor = normalize(author)
        let wantedNarrator = normalize(narrator)

        return editions.map { edition -> HardcoverCandidate in
            let delta = edition.audioSeconds.map { $0 - localSeconds }
            let haystack = edition.contributors.map(normalize)
            let authorMatches = !wantedAuthor.isEmpty
                && haystack.contains { $0.contains(wantedAuthor) || wantedAuthor.contains($0) }
            // Only a conflict if there WAS something to compare against on both sides.
            let authorConflicts = !wantedAuthor.isEmpty && !haystack.isEmpty && !authorMatches
            let narratorPool = (edition.narrators.isEmpty ? edition.contributors : edition.narrators)
                .map(normalize)
            let narratorMatches = !wantedNarrator.isEmpty
                && narratorPool.contains { $0.contains(wantedNarrator) || wantedNarrator.contains($0) }

            var score = 0.0
            // Duration dominates: the whole point is separating recordings of the same book.
            if let delta {
                let off = Double(abs(delta))
                switch off {
                case ...Double(nearExactToleranceSeconds): score += 100
                case ...120:                               score += 70
                case ...600:                               score += 35
                case ...1800:                              score += 10
                default:                                   score += 0
                }
            }
            if authorMatches { score += 20 }
            // Bigger than the maximum runtime bonus (100), deliberately. A listed author that
            // isn't ours is strong evidence of the wrong book, and it has to outweigh even a
            // perfect runtime — otherwise the sheet leads with someone else's book that merely
            // happens to run the same length.
            if authorConflicts { score -= 150 }
            if narratorMatches { score += 15 }
            if edition.format?.lowercased().contains("audio") == true { score += 5 }

            return HardcoverCandidate(edition: edition,
                                      durationDelta: delta,
                                      authorMatches: authorMatches,
                                      authorConflicts: authorConflicts,
                                      score: score)
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            // Same score: prefer the smaller runtime gap, then a stable id order.
            let a = $0.durationDelta.map(abs) ?? .max
            let b = $1.durationDelta.map(abs) ?? .max
            return a != b ? a < b : $0.edition.id < $1.edition.id
        }
    }

    /// The single candidate we're willing to apply without asking, or nil if it's a judgement call.
    static func autoApplicable(_ candidates: [HardcoverCandidate]) -> HardcoverCandidate? {
        guard let best = candidates.first, best.isNearExact else { return nil }
        // If a second edition is also within tolerance we genuinely can't tell them apart —
        // that's exactly the case that belongs in front of the user.
        let alsoExact = candidates.dropFirst().contains { $0.isNearExact }
        return alsoExact ? nil : best
    }

    // MARK: Helpers

    static func searchTerm(title: String, author: String?) -> String {
        var t = title
        // Strip the bracketed edition noise publishers put in filenames — "(Full-Cast Edition)",
        // "[Unabridged]" — which hurts a fuzzy title search more than it helps.
        t = t.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let author, !author.isEmpty else { return t }
        return "\(t) \(author)"
    }

    private static func normalize(_ s: String?) -> String {
        guard let s else { return "" }
        return s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

// MARK: - Wire decoding

/// `search { results }` is an opaque Typesense payload; reach in for the book ids only.
private struct SearchEnvelope: Decodable {
    let search: Results?

    struct Results: Decodable {
        let results: TypesenseResults?
    }

    struct TypesenseResults: Decodable {
        let hits: [Hit]?
        struct Hit: Decodable {
            let document: Document?
            struct Document: Decodable {
                // Typesense stores the id as a string even though the API uses Int.
                let id: StringOrInt?
            }
        }
    }

    var bookIds: [Int] {
        (search?.results?.hits ?? []).compactMap { $0.document?.id?.intValue }
    }
}

private struct EditionsEnvelope: Decodable {
    let editions: [Row]

    struct Row: Decodable {
        let id: Int
        let book_id: Int
        let title: String?
        let audio_seconds: Int?
        let asin: String?
        let isbn_13: String?
        let edition_format: String?
        let contributions: [Contribution]?
        let cached_contributors: ContributorBlob?
        let image: Image?
        let book: BookRef?

        struct Image: Decodable { let url: String? }
        struct BookRef: Decodable {
            let id: Int?; let slug: String?; let title: String?
            let contributions: [Contribution]?
        }
        struct Contribution: Decodable {
            let contribution: String?   // role: nil/"author"/"Narrator"/"translator"…
            let author: Person?
            struct Person: Decodable { let name: String? }

            var isNarrator: Bool {
                (contribution ?? "").localizedCaseInsensitiveContains("narrat")
            }
        }

        var model: HardcoverEdition {
            // The `contributions` relation is authoritative; `cached_contributors` is a
            // denormalized blob whose shape has drifted over time. Falling back to it rather
            // than depending on it matters: when it parses to nothing, every author check
            // fails and NO edition is ever confident enough to auto-match.
            let live = contributions ?? []
            let narrators = live.filter(\.isNarrator).compactMap { $0.author?.name }
            // Author credit commonly lives on the BOOK while the edition lists only the
            // narrator, so both sources feed the author check.
            let bookLevel = (book?.contributions ?? []).compactMap { $0.author?.name }
            var names = live.compactMap { $0.author?.name } + bookLevel
            if names.isEmpty { names = cached_contributors?.names ?? [] }
            return HardcoverEdition(
                id: id,
                bookId: book?.id ?? book_id,
                bookSlug: book?.slug,
                bookTitle: book?.title ?? title ?? "",
                editionTitle: title,
                audioSeconds: audio_seconds,
                asin: asin,
                isbn13: isbn_13,
                format: edition_format,
                coverURL: image?.url,
                contributors: Array(Set(names)).sorted(),
                narrators: narrators
            )
        }
    }
}

/// `cached_contributors` is denormalized JSON whose shape has changed over time — sometimes an
/// array of objects, sometimes nested under `author`/`contribution`. Pull out any `name` found
/// rather than modelling a shape that could shift under us.
private struct ContributorBlob: Decodable {
    let names: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let any = try? container.decode(AnyJSON.self)
        names = AnyJSON.collectStrings(forKey: "name", in: any)
    }
}

/// Accepts a JSON value that may be a string or a number.
private struct StringOrInt: Decodable {
    let intValue: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { intValue = i }
        else if let s = try? c.decode(String.self) { intValue = Int(s) }
        else { intValue = nil }
    }
}

/// Small untyped JSON tree, only used to dig values out of Hardcover's denormalized blobs.
private indirect enum AnyJSON: Decodable {
    case string(String), number(Double), bool(Bool), null
    case array([AnyJSON]), object([String: AnyJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([AnyJSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: AnyJSON].self) { self = .object(v) }
        else { self = .null }
    }

    static func collectStrings(forKey key: String, in json: AnyJSON?) -> [String] {
        guard let json else { return [] }
        switch json {
        case .array(let items):
            return items.flatMap { collectStrings(forKey: key, in: $0) }
        case .object(let dict):
            var found: [String] = []
            if case .string(let s)? = dict[key], !s.isEmpty { found.append(s) }
            for (k, v) in dict where k != key {
                found.append(contentsOf: collectStrings(forKey: key, in: v))
            }
            return found
        default:
            return []
        }
    }
}
