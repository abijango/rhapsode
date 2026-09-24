import Foundation
import Testing
@testable import SmartSpeechKit

@Suite("Semantic edit planning")
struct SemanticEditPlannerTests {
    @Test("short pauses are preserved")
    func preservesShortPause() {
        let planner = SemanticEditPlanner()
        let edits = planner.edits(for: [
            SemanticRegion(start: 1, end: 1.17, kind: .silence, confidence: 1)
        ])

        #expect(edits.isEmpty)
    }

    @Test("removes the centre of a longer pause")
    func removesPauseCentre() {
        let planner = SemanticEditPlanner()
        let edits = planner.edits(for: [
            SemanticRegion(start: 1, end: 2, kind: .silence, confidence: 1)
        ])

        #expect(edits.count == 1)
        #expect(edits[0].kind == .compressPause)
        #expect(abs(edits[0].start - 1.11) < 0.001)
        #expect(abs(edits[0].end - 1.89) < 0.001)
    }

    @Test("uncertain and speech regions are protected")
    func protectsSpeechAndUncertainty() {
        let planner = SemanticEditPlanner()
        let edits = planner.edits(for: [
            SemanticRegion(start: 0, end: 4, kind: .speech, confidence: 1),
            SemanticRegion(start: 5, end: 9, kind: .uncertain, confidence: 0.2)
        ])

        #expect(edits.isEmpty)
    }

    @Test("sustained music without speech is removed with handles")
    func removesMusicOnly() {
        let planner = SemanticEditPlanner()
        let edits = planner.edits(for: [
            SemanticRegion(start: 10, end: 16, kind: .musicOnly, confidence: 0.9)
        ])

        #expect(edits == [
            AudioEdit(start: 10.25, end: 15.65, kind: .removeMusic)
        ])
    }

    @Test("edit map slices one global removal consistently across chunks")
    func slicesAcrossChunks() {
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 11.5, end: 13.5, kind: .compressPause)
        ])

        #expect(map.removals(in: 0..<12) == [
            SilenceRegion(start: 11.5, end: 12)
        ])
        #expect(map.removals(in: 12..<24) == [
            SilenceRegion(start: 0, end: 1.5)
        ])
    }

    @Test("overlapping edits are merged")
    func mergesEdits() {
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 1, end: 2, kind: .compressPause),
            AudioEdit(start: 1.8, end: 3, kind: .compressPause)
        ])

        #expect(map.edits == [
            AudioEdit(start: 1, end: 3, kind: .compressPause)
        ])
    }

    @Test("render boundary moves beyond an edit instead of splitting it")
    func movesRenderBoundary() {
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 11.5, end: 13.5, kind: .compressPause)
        ])

        #expect(map.renderEnd(from: 0, preferredEnd: 12, sourceEnd: 30) == 13.5)
    }
}
