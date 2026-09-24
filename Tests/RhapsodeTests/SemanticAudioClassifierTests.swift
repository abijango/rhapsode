import Foundation
import Testing
@testable import Rhapsode

@Suite("Semantic audio classifier policy")
struct SemanticAudioClassifierTests {
    @Test("authorizes only sustained, fully covered music with explicit quiet voice evidence")
    func authorizesSustainedMusicOnly() {
        let policy = SemanticAudioClassifier.Policy(
            minimumMusicConfidence: 0.95,
            maximumVoiceConfidence: 0.02,
            minimumSustainedMusicSeconds: 6
        )

        let decision = policy.decide(
            windows: [
                window(0...3, music: 0.99, speech: 0.01, singing: 0.01),
                window(3...6, music: 0.98, speech: 0.01, singing: 0.01),
                window(6...9, music: 0.97, speech: 0.01, singing: 0.01)
            ],
            analysis: .completed(coverage: 0...9)
        )

        #expect(decision.authorizedMusicOnlyRanges == [0...9])
        #expect(decision.isComplete)
    }

    @Test("preserves speech over music and removes its whole overlap from authorization")
    func preservesSpeechOverMusic() {
        let policy = SemanticAudioClassifier.Policy()

        let decision = policy.decide(
            windows: [
                window(0...3, music: 0.99, speech: 0.01, singing: 0.01),
                window(3...6, music: 0.99, speech: 0.70, singing: 0.01),
                window(6...9, music: 0.99, speech: 0.01, singing: 0.01),
                window(9...12, music: 0.99, speech: 0.01, singing: 0.01),
                window(12...15, music: 0.99, speech: 0.01, singing: 0.01)
            ],
            analysis: .completed(coverage: 0...15)
        )

        #expect(decision.authorizedMusicOnlyRanges == [6...15])
        #expect(decision.uncertainRanges.contains {
            $0.lowerBound <= 3 && $0.upperBound >= 6
        })
    }

    @Test("preserves singing even when music is otherwise strong")
    func preservesSinging() {
        let decision = SemanticAudioClassifier.Policy().decide(
            windows: [
                window(0...3, music: 0.99, speech: 0.01, singing: 0.85),
                window(3...6, music: 0.99, speech: 0.01, singing: 0.01),
                window(6...9, music: 0.99, speech: 0.01, singing: 0.01),
                window(9...12, music: 0.99, speech: 0.01, singing: 0.01)
            ],
            analysis: .completed(coverage: 0...12)
        )

        #expect(decision.authorizedMusicOnlyRanges == [3...12])
        #expect(decision.uncertainRanges.contains(0...3))
    }

    @Test("fails closed without independent speech and singing evidence")
    func preservesWhenVoiceEvidenceIsMissing() {
        let decision = SemanticAudioClassifier.Policy().decide(
            windows: [
                .init(range: 0...3, musicConfidence: 0.99, voiceConfidences: [:]),
                .init(range: 3...6, musicConfidence: 0.99, voiceConfidences: [:]),
                .init(range: 6...9, musicConfidence: 0.99, voiceConfidences: [:])
            ],
            analysis: .completed(coverage: 0...9)
        )

        #expect(decision.authorizedMusicOnlyRanges.isEmpty)
        #expect(decision.uncertainRanges == [0...9])
    }

    @Test("preserves short stingers")
    func preservesShortStingers() {
        let decision = SemanticAudioClassifier.Policy().decide(
            windows: [
                window(0...3, music: 0.99, speech: 0.01, singing: 0.01),
                window(3...6, music: 0.99, speech: 0.01, singing: 0.01)
            ],
            analysis: .completed(coverage: 0...6)
        )

        #expect(decision.authorizedMusicOnlyRanges.isEmpty)
        #expect(decision.uncertainRanges == [0...6])
    }

    @Test("preserves a music region with an unknown end")
    func preservesUnclosedMusic() {
        let decision = SemanticAudioClassifier.Policy().decide(
            windows: [
                window(0...3, music: 0.99, speech: 0.01, singing: 0.01),
                window(3...6, music: 0.99, speech: 0.01, singing: 0.01),
                window(6...9, music: 0.99, speech: 0.01, singing: 0.01)
            ],
            analysis: .incomplete(coverage: 0...9)
        )

        #expect(decision.authorizedMusicOnlyRanges.isEmpty)
        #expect(decision.uncertainRanges == [0...9])
    }

    @Test("preserves all content on classifier failure or cancellation")
    func preservesOnFailureOrCancellation() {
        let windows = [
            window(0...3, music: 0.99, speech: 0.01, singing: 0.01),
            window(3...6, music: 0.99, speech: 0.01, singing: 0.01),
            window(6...9, music: 0.99, speech: 0.01, singing: 0.01)
        ]
        let policy = SemanticAudioClassifier.Policy()

        #expect(policy.decide(windows: windows, analysis: .failed).authorizedMusicOnlyRanges.isEmpty)
        #expect(policy.decide(windows: windows, analysis: .cancelled).authorizedMusicOnlyRanges.isEmpty)
    }

    @Test("label discovery requires installed music plus both speech and singing protections")
    func labelDiscoveryRequiresExplicitVoiceProtections() {
        #expect(SemanticAudioClassifier.Labels.discover(in: ["Music", "Speech", "Singing"]) != nil)
        #expect(SemanticAudioClassifier.Labels.discover(in: ["Music", "Speech"]) == nil)
        #expect(SemanticAudioClassifier.Labels.discover(in: ["Music", "Singing"]) == nil)
        #expect(SemanticAudioClassifier.Labels.discover(in: ["Speech", "Singing"]) == nil)
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
            voiceConfidences: [
                "Speech": speech,
                "Singing": singing
            ]
        )
    }
}
