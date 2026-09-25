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

    @Test("removes the trailing tail of a longer pause, matching SilencePolicy placement")
    func removesPauseTail() {
        let planner = SemanticEditPlanner()
        let edits = planner.edits(for: [
            SemanticRegion(start: 1, end: 2, kind: .silence, confidence: 1)
        ])

        // Default settings: target = minKeptSilence + (D - minSilenceDuration) * residualSlope
        //                          = 0.18 + (1.0 - 0.28) * 0.12 = 0.2664
        // Kept silence is leading (same as `TrimRenderer.plan`), so the removal is the tail
        // and always ends exactly at the region end.
        #expect(edits.count == 1)
        #expect(edits[0].kind == .compressPause)
        #expect(abs(edits[0].start - 1.2664) < 0.001)
        #expect(edits[0].end == 2)
    }

    @Test("compressPause removal matches the legacy SilencePolicy / TrimRenderer.plan path, per tier")
    func compressPauseMatchesLegacyPolicy() {
        let sampleRate = 48_000.0
        let regionStart: TimeInterval = 10
        let durations: [TimeInterval] = [0.15, 0.19, 0.25, 0.30, 0.45, 0.80, 1.5, 3.0]

        for preset in SmartSpeechSettings.Preset.allCases {
            let settings = SmartSpeechSettings(preset: preset)
            let planner = SemanticEditPlanner(policy: SemanticEditPolicy(silenceSettings: settings))

            for D in durations {
                let region = SemanticRegion(start: regionStart, end: regionStart + D,
                                            kind: .silence, confidence: 1)
                let edits = planner.edits(for: [region])

                // Legacy path: identical D→target mapping and kept-silence placement.
                let totalFrames = Int((regionStart + D + 5) * sampleRate)
                let plan = TrimRenderer(settings: settings).plan(
                    regions: [SilenceRegion(start: regionStart, end: regionStart + D)],
                    totalFrames: totalFrames, sampleRate: sampleRate)
                let joint = plan.joints[0]
                let legacyStart = Double(joint.outCut) / sampleRate
                let legacyEnd = Double(joint.inResume) / sampleRate

                if legacyEnd - legacyStart < 1e-4 {
                    #expect(edits.isEmpty, "\(preset) D=\(D): legacy path keeps the pause whole")
                } else {
                    #expect(edits.count == 1, "\(preset) D=\(D)")
                    if let edit = edits.first {
                        #expect(abs(edit.start - legacyStart) < 1e-3, "\(preset) D=\(D) start")
                        #expect(abs(edit.end - legacyEnd) < 1e-3, "\(preset) D=\(D) end")
                    }
                }
            }
        }
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

    @Test("render boundary chains past a second edit reached by extending past the first")
    func movesRenderBoundaryPastChainedEdit() {
        // Landing inside the first edit and extending to its end can land inside a second edit
        // that starts before the first one's end — the boundary must keep moving until it clears
        // every edit, not stop after a single hop (the live producer's chunk-seam bug).
        let map = PlaybackEditMap(edits: [
            AudioEdit(start: 10, end: 11, kind: .compressPause),
            AudioEdit(start: 10.5, end: 12, kind: .removeMusic)
        ])

        #expect(map.renderEnd(from: 0, preferredEnd: 10.2, sourceEnd: 30) == 12)
    }
}
