import Testing
@testable import Rhapsode

@Suite("Playback speed savings from consumed output")
struct PlaybackSpeedSavingsAccumulatorTests {
    @Test("normal speed and slower playback earn no speed savings")
    func normalAndSlow() {
        var accumulator = PlaybackSpeedSavingsAccumulator()
        #expect(accumulator.record(outputSeconds: 0, rate: 1) == 0)
        #expect(accumulator.record(outputSeconds: 3, rate: 1) == 0)
        accumulator.reset()
        #expect(accumulator.record(outputSeconds: 0, rate: 0.8) == 0)
        #expect(accumulator.record(outputSeconds: 2, rate: 0.8) == 0)
    }

    @Test("two times speed credits only consumed playback")
    func twiceSpeed() {
        var accumulator = PlaybackSpeedSavingsAccumulator()
        #expect(accumulator.record(outputSeconds: 0, rate: 2) == 0)
        #expect(accumulator.record(outputSeconds: 1, rate: 2) == 1)
        #expect(accumulator.record(outputSeconds: 1, rate: 2) == 0)
        #expect(accumulator.record(outputSeconds: 2, rate: 2) == 1)
    }

    @Test("a delayed tick counts audio consumed; resets and rate changes do not invent savings")
    func discontinuities() {
        var accumulator = PlaybackSpeedSavingsAccumulator()
        #expect(accumulator.record(outputSeconds: 0, rate: 1.5) == 0)
        #expect(accumulator.record(outputSeconds: 1, rate: 1.5) == 0.5)
        #expect(accumulator.record(outputSeconds: 10, rate: 1.5) == 4.5)
        #expect(accumulator.record(outputSeconds: 11, rate: 2) == 0)
        accumulator.reset()
        #expect(accumulator.record(outputSeconds: 0, rate: 2) == 0)
        #expect(accumulator.record(outputSeconds: 1, rate: 2) == 1)
    }

    @Test("the first offline book contribution remains owned by this device")
    func firstBookContribution() {
        let audiobook = Audiobook(title: "Book", sourcePath: "book.m4b")
        audiobook.addPlaybackSpeedSaved(5)
        #expect(audiobook.myPlaybackSpeedSavedSeconds == 5)
        #expect(audiobook.playbackSpeedSavedSeconds == 5)
        #expect((audiobook.myPlaybackSpeedSavedSeconds ?? 0) + 10 == 15)
    }
}
