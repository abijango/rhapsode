#if PERSONAL_RUBBERBAND
import Testing
@testable import Rhapsode

@Suite("Adaptive playback-speed policy")
struct AdaptiveSpeedPolicyTests {
    @Test("defaults to opt-out and preserves the selected speed")
    func defaultsToOptOut() {
        let policy = AdaptiveSpeedPolicy()
        let speech = [window(0...8, music: 0.01, speech: 0.99, singing: 0.01)]

        #expect(rate(policy, selected: 1.0, windows: speech, coverage: 0...8) == 1.0)
        #expect(rate(policy, selected: 1.6, windows: speech, coverage: 0...8) == 1.6)
    }

    @Test("boosts only sustained, positively classified pure speech by 0.15x")
    func boostsConfirmedPureSpeech() {
        let policy = AdaptiveSpeedPolicy(isEnabled: true)
        let speech = [
            window(0...4, music: 0.01, speech: 0.99, singing: 0.01),
            window(4...8, music: 0.01, speech: 0.97, singing: 0.01)
        ]
        let briefSpeech = [window(0...1, music: 0.01, speech: 0.99, singing: 0.01)]

        #expect(
            abs(rate(policy, selected: 1.0, windows: speech, coverage: 0...8) - 1.15) < 0.000_001
        )
        #expect(
            abs(rate(policy, selected: 1.8, windows: speech, coverage: 0...8) - 1.95) < 0.000_001
        )
        #expect(
            rate(policy, selected: 1.0, windows: briefSpeech, coverage: 0...1) == 1.0
        )
        #expect(
            rate(
                policy,
                selected: 1.0,
                windows: speech,
                coverage: 0...8,
                analysis: .incomplete(coverage: 0...8)
            ) == 1.0
        )
    }

    @Test("caps boosted playback at three times")
    func capsAtThreeTimes() {
        let policy = AdaptiveSpeedPolicy(isEnabled: true)
        let speech = [window(0...8, music: 0.01, speech: 0.99, singing: 0.01)]

        #expect(
            rate(policy, selected: 2.95, windows: speech, coverage: 0...8) == 3.0
        )
        #expect(
            rate(policy, selected: 3.0, windows: speech, coverage: 0...8) == 3.0
        )
    }

    @Test("does not infer speech from music, singing, speech-over-music, or uncertain evidence")
    func requiresPositivePureSpeechEvidence() {
        let policy = AdaptiveSpeedPolicy(isEnabled: true)

        #expect(
            rate(
                policy,
                selected: 1.4,
                windows: [window(0...8, music: 0.99, speech: 0.01, singing: 0.01)],
                coverage: 0...8
            ) == 1.0
        )
        #expect(
            rate(
                policy,
                selected: 1.4,
                windows: [window(0...8, music: 0.25, speech: 0.01, singing: 0.99)],
                coverage: 0...8
            ) == 1.4
        )
        #expect(
            rate(
                policy,
                selected: 1.4,
                windows: [window(0...8, music: 0.99, speech: 0.99, singing: 0.01)],
                coverage: 0...8
            ) == 1.4
        )
        #expect(
            rate(
                policy,
                selected: 1.4,
                windows: [window(0...8, music: 0.35, speech: 0.35, singing: 0.01)],
                coverage: 0...8
            ) == 1.4
        )
        #expect(
            rate(
                policy,
                selected: 1.0,
                windows: [window(0...8, music: 0.35, speech: 0.35, singing: 0.01)],
                coverage: 0...8
            ) == 1.0
        )
        #expect(
            rate(
                policy,
                selected: 1.0,
                windows: [.init(range: 0...8, musicConfidence: 0.99, voiceConfidences: ["Singing": 0.01])],
                coverage: 0...8
            ) == 1.0
        )
    }

    @Test("keeps the selected speed when any requested time is uncovered")
    func protectsUncoveredAudio() {
        let policy = AdaptiveSpeedPolicy(isEnabled: true)
        let partiallyCoveredSpeech = [window(0...6, music: 0.01, speech: 0.99, singing: 0.01)]

        #expect(rate(policy, selected: 1.6, windows: partiallyCoveredSpeech, coverage: 0...8) == 1.6)
    }

    private func rate(
        _ policy: AdaptiveSpeedPolicy,
        selected: Double,
        windows: [SemanticAudioClassifier.Window],
        coverage: ClosedRange<TimeInterval>,
        analysis: SemanticAudioClassifier.Analysis? = nil
    ) -> Double {
        policy.playbackRate(
            selectedRate: selected,
            windows: windows,
            analysis: analysis ?? .completed(coverage: coverage)
        )
    }

    private func window(
        _ range: ClosedRange<TimeInterval>,
        music: Double,
        speech: Double,
        singing: Double
    ) -> SemanticAudioClassifier.Window {
        .init(
            range: range,
            musicConfidence: music,
            voiceConfidences: ["Speech": speech, "Singing": singing]
        )
    }
}
#endif
