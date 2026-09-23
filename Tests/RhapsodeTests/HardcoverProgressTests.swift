import Foundation
import Testing
@testable import Rhapsode

/// What number gets sent to Hardcover. Three ways to get this wrong are all silent — the
/// sync still "works", it just reports the wrong place in the book — so they're pinned here.
@Suite("Hardcover — progress scaling")
struct HardcoverProgressTests {

    @Test("Progress is scaled into the EDITION's runtime, not the local file's")
    func scalesToEdition() {
        // Local file 39,000s, Hardcover's edition 39,240s (different intro/outro).
        // Halfway through the book is halfway through the edition, not 19,500s.
        let seconds = HardcoverSyncService.editionSeconds(
            progress: 0.5, editionRuntime: 39_240, localDuration: 39_000)
        #expect(seconds == 19_620)
    }

    @Test("Falls back to the local runtime when the edition lists none")
    func fallsBackToLocalDuration() {
        #expect(HardcoverSyncService.editionSeconds(
            progress: 0.25, editionRuntime: nil, localDuration: 40_000) == 10_000)
        // A zero runtime is as useless as a missing one.
        #expect(HardcoverSyncService.editionSeconds(
            progress: 0.25, editionRuntime: 0, localDuration: 40_000) == 10_000)
    }

    @Test("Never reports past the end, or before the start")
    func clampsToTheBook() {
        #expect(HardcoverSyncService.editionSeconds(
            progress: 1.4, editionRuntime: 39_240, localDuration: 39_000) == 39_240)
        #expect(HardcoverSyncService.editionSeconds(
            progress: -0.2, editionRuntime: 39_240, localDuration: 39_000) == 0)
    }

    @Test("A non-finite progress reports the start, never a finish")
    func survivesNonFinite() {
        // Both NaN and infinity collapse to 0, deliberately. `bookProgress` already clamps, so
        // a non-finite value here means something is broken upstream — and the safe reading of
        // a broken value is "no progress". Mapping +infinity to 1.0 instead would cross the
        // finish threshold and offer to publicly mark the book Read on the strength of a bug.
        #expect(HardcoverSyncService.editionSeconds(
            progress: .nan, editionRuntime: 39_240, localDuration: 39_000) == 0)
        #expect(HardcoverSyncService.editionSeconds(
            progress: .infinity, editionRuntime: 39_240, localDuration: 39_000) == 0)
    }

    @Test("A finished book reports the edition's full runtime")
    func finishedIsFull() {
        #expect(HardcoverSyncService.editionSeconds(
            progress: 1.0, editionRuntime: 39_240, localDuration: 39_000) == 39_240)
    }
}
