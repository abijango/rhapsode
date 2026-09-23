import Foundation
import Testing
@testable import Rhapsode

/// Which read-through a listening session joins. This decides whether re-listening to a book
/// you've already finished appears as a SECOND read on Hardcover or silently overwrites the
/// first one — and overwriting is destructive to reading history that can't be recovered from
/// the app. The rule has changed three times while debugging, so it's pinned here.
@Suite("Hardcover — re-read planning")
struct HardcoverReadPlanTests {

    @Test("A book never read before starts its first read-through")
    func firstEverRead() {
        #expect(HardcoverReadPlan.plan(for: []) == .startNew)
    }

    @Test("An in-progress read is continued, not duplicated")
    func continuesOpenRead() {
        let rows = [HardcoverReadRow(id: 91, finishedAt: nil)]
        #expect(HardcoverReadPlan.plan(for: rows) == .reuse(91))
    }

    /// The case the whole feature turns on: a finished book being listened to again.
    @Test("Re-listening to a finished book starts a NEW read, preserving the old one")
    func reListenStartsNewRead() {
        let rows = [HardcoverReadRow(id: 40, finishedAt: "2024-03-01")]
        #expect(HardcoverReadPlan.plan(for: rows) == .startNew)
    }

    @Test("A finished read plus a newer open one continues the open one")
    func mixedHistoryContinuesOpen() {
        let rows = [
            HardcoverReadRow(id: 40, finishedAt: "2024-03-01"),
            HardcoverReadRow(id: 91, finishedAt: nil),
        ]
        #expect(HardcoverReadPlan.plan(for: rows) == .reuse(91))
    }

    @Test("Several finished reads still start a new one — none may be overwritten")
    func multipleFinishedReadsStartNew() {
        let rows = [
            HardcoverReadRow(id: 12, finishedAt: "2022-01-01"),
            HardcoverReadRow(id: 40, finishedAt: "2024-03-01"),
        ]
        #expect(HardcoverReadPlan.plan(for: rows) == .startNew)
    }

    @Test("With more than one open read the most recent wins")
    func prefersMostRecentOpenRead() {
        let rows = [
            HardcoverReadRow(id: 12, finishedAt: nil),
            HardcoverReadRow(id: 91, finishedAt: nil),
        ]
        #expect(HardcoverReadPlan.plan(for: rows) == .reuse(91))
    }

    @Test("An empty finished_at string counts as finished, not open")
    func openMeansNilNotEmpty() {
        #expect(HardcoverReadRow(id: 1, finishedAt: nil).isOpen)
        #expect(!HardcoverReadRow(id: 1, finishedAt: "2024-03-01").isOpen)
    }
}
