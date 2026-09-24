import Testing
@testable import SmartSpeechKit

@Suite("Semantic edit protection contract")
struct SemanticEditProtectionContractTests {
    @Test("all speech-like and uncertain classifications remain untouched")
    func protectsSpeechLikeRegions() {
        let protectedKinds: [SemanticAudioKind] = [
            .speech, .breath, .speechOverMusic, .singing, .soundEffect, .uncertain
        ]
        let regions = protectedKinds.enumerated().map { index, kind in
            SemanticRegion(start: Double(index * 5), end: Double(index * 5 + 4),
                           kind: kind, confidence: 1)
        }

        #expect(SemanticEditPlanner().edits(for: regions).isEmpty)
    }

    @Test("low-confidence silence is preserved rather than treated as a candidate")
    func protectsLowConfidenceSilence() {
        let region = SemanticRegion(start: 2, end: 8, kind: .silence, confidence: 0.69)

        #expect(SemanticEditPlanner().edits(for: [region]).isEmpty)
    }
}
