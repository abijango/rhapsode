import Testing
@testable import SmartSpeechKit

@Suite("LivePlaybackClock — reject stale player-node times")
struct LivePlaybackClockTests {
    @Test("In-range sample time is used as-is")
    func inRange() {
        let played = LivePlaybackClock.sessionPlayed(
            rawSeconds: 10, scheduledOutput: 24, lastGood: 9
        )
        #expect(played == 10)
    }

    @Test("Nil / NaN / negative fall back to lastGood, clamped to scheduled")
    func invalidRaw() {
        #expect(LivePlaybackClock.sessionPlayed(rawSeconds: nil, scheduledOutput: 24, lastGood: 5) == 5)
        #expect(LivePlaybackClock.sessionPlayed(rawSeconds: .nan, scheduledOutput: 24, lastGood: 5) == 5)
        #expect(LivePlaybackClock.sessionPlayed(rawSeconds: -2, scheduledOutput: 24, lastGood: 5) == 5)
        #expect(LivePlaybackClock.sessionPlayed(rawSeconds: nil, scheduledOutput: 4, lastGood: 99) == 4)
        #expect(LivePlaybackClock.sessionPlayed(rawSeconds: nil, scheduledOutput: 24, lastGood: -1) == 0)
    }

    @Test("Stale large sample time (previous session) is rejected")
    func stalePreviousSession() {
        // Config-change / engine restart: scheduled reset to ~12s, node still
        // reports 600s from the previous session.
        let played = LivePlaybackClock.sessionPlayed(
            rawSeconds: 600, scheduledOutput: 12, lastGood: 0
        )
        #expect(played == 0)
    }

    @Test("Slightly past scheduled (final buffer drain) is accepted")
    func drainSlack() {
        let played = LivePlaybackClock.sessionPlayed(
            rawSeconds: 24.4, scheduledOutput: 24, lastGood: 24
        )
        #expect(played == 24.4)
        let rejected = LivePlaybackClock.sessionPlayed(
            rawSeconds: 26, scheduledOutput: 24, lastGood: 24
        )
        #expect(rejected == 24)
    }
}
