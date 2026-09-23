import Foundation
import Testing
@testable import Rhapsode

/// The scorer is the part of the Hardcover integration that can be wrong *quietly*: a bad pick
/// still syncs, it just syncs to the wrong book. These lock the ranking behaviour that makes
/// the pick defensible — runtime proximity first, everything else as a tiebreak.
@Suite("Hardcover — edition matching")
struct HardcoverMatcherTests {

    /// 11h 8m — a plausible full-cast Harry Potter runtime.
    let localDuration: Double = 40_080

    private func edition(_ id: Int,
                         seconds: Int?,
                         contributors: [String] = ["J.K. Rowling"],
                         narrators: [String] = [],
                         format: String? = "audiobook") -> HardcoverEdition {
        HardcoverEdition(
            id: id, bookId: 1, bookSlug: "harry-potter",
            bookTitle: "Harry Potter and the Philosopher's Stone",
            editionTitle: nil, audioSeconds: seconds, asin: nil, isbn13: nil,
            format: format, coverURL: nil, contributors: contributors, narrators: narrators)
    }

    @Test("Runtime, not title, picks the edition")
    func runtimeWins() {
        // Three editions of the same book, indistinguishable by title and author. Only the
        // middle one is the recording actually on disk.
        let editions = [
            edition(1, seconds: 30_000),          // a different, shorter recording
            edition(2, seconds: 40_084),          // ours, 4s off
            edition(3, seconds: 45_000),          // another recording
        ]
        let ranked = HardcoverMatcher.rank(editions,
                                           localDuration: localDuration,
                                           author: "J.K. Rowling",
                                           narrator: nil)
        #expect(ranked.first?.edition.id == 2)
        #expect(ranked.first?.isNearExact == true)
    }

    @Test("A near-exact single candidate auto-applies")
    func autoAppliesUnambiguous() {
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: 40_090), edition(2, seconds: 52_000)],
            localDuration: localDuration, author: "J.K. Rowling", narrator: nil)
        #expect(HardcoverMatcher.autoApplicable(ranked)?.edition.id == 1)
    }

    @Test("Two editions within tolerance are a judgement call, not an auto-match")
    func refusesAmbiguousAutoMatch() {
        // Same recording listed twice (a remaster, a regional release) — we genuinely cannot
        // tell which the user means, so this must reach the match sheet.
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: 40_082), edition(2, seconds: 40_075)],
            localDuration: localDuration, author: "J.K. Rowling", narrator: nil)
        #expect(HardcoverMatcher.autoApplicable(ranked) == nil)
    }

    @Test("A close runtime by a different author does not auto-apply")
    func requiresAuthorAgreement() {
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: 40_081, contributors: ["Someone Else"])],
            localDuration: localDuration, author: "J.K. Rowling", narrator: nil)
        #expect(ranked.first?.isNearExact == false)
        #expect(HardcoverMatcher.autoApplicable(ranked) == nil)
    }

    @Test("Narrator breaks a tie between equal runtimes")
    func narratorTiebreak() {
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: 41_000, contributors: ["J.K. Rowling", "Jim Dale"],
                     narrators: ["Jim Dale"]),
             edition(2, seconds: 41_000, contributors: ["J.K. Rowling", "Stephen Fry"],
                     narrators: ["Stephen Fry"])],
            localDuration: localDuration, author: "J.K. Rowling", narrator: "Stephen Fry")
        #expect(ranked.first?.edition.id == 2)
    }

    /// Regression: Hardcover often returns no contributor rows for an edition. Requiring a
    /// POSITIVE author match meant those never auto-matched — which silently disabled
    /// auto-matching for whole books, with nothing on screen explaining why.
    @Test("Missing contributor data does not block a near-exact runtime match")
    func missingContributorsStillMatches() {
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: 40_084, contributors: [])],
            localDuration: localDuration, author: "J.K. Rowling", narrator: nil)
        #expect(ranked.first?.authorMatches == false)
        #expect(ranked.first?.authorConflicts == false)
        #expect(ranked.first?.isNearExact == true)
        #expect(HardcoverMatcher.autoApplicable(ranked)?.edition.id == 1)
    }

    @Test("A contradicting author still blocks, and is ranked below a worse-runtime match")
    func conflictOutranksRuntime() {
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: 40_081, contributors: ["Someone Else"]),
             edition(2, seconds: 41_500, contributors: ["J.K. Rowling"])],
            localDuration: localDuration, author: "J.K. Rowling", narrator: nil)
        #expect(ranked.first?.edition.id == 2)
        #expect(HardcoverMatcher.autoApplicable(ranked) == nil)
    }

    @Test("Editions with no runtime rank last and never auto-apply")
    func noRuntimeRanksLast() {
        let ranked = HardcoverMatcher.rank(
            [edition(1, seconds: nil), edition(2, seconds: 44_000)],
            localDuration: localDuration, author: "J.K. Rowling", narrator: nil)
        #expect(ranked.first?.edition.id == 2)
        #expect(ranked.last?.isNearExact == false)
        #expect(HardcoverMatcher.autoApplicable(ranked) == nil)
    }

    @Test("No candidates at all is not a match")
    func emptyIsSafe() {
        let ranked = HardcoverMatcher.rank([], localDuration: localDuration,
                                           author: "J.K. Rowling", narrator: nil)
        #expect(ranked.isEmpty)
        #expect(HardcoverMatcher.autoApplicable(ranked) == nil)
    }

    @Test("Search term drops the bracketed edition noise publishers put in filenames")
    func searchTermCleanup() {
        let term = HardcoverMatcher.searchTerm(
            title: "Harry Potter and the Goblet of Fire (Full-Cast Edition) [Unabridged]",
            author: "J.K. Rowling")
        #expect(term == "Harry Potter and the Goblet of Fire J.K. Rowling")
    }

    @Test("Evidence line states the runtime comparison the match rests on")
    func evidenceIsLegible() {
        let ranked = HardcoverMatcher.rank([edition(1, seconds: 40_084)],
                                           localDuration: localDuration,
                                           author: "J.K. Rowling", narrator: nil)
        #expect(ranked.first?.evidence == "11h 8m · matches your file (±4s)")
    }
}
