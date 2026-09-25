import Foundation
import Testing
@testable import SmartSpeechKit

@Suite("TrimRenderer — bounded source seam")
struct BoundedSpliceRendererTests {
    private let sampleRate = 48_000.0

    @Test("bounded two-sided splice crossfades without a hard cut")
    func boundedSpliceCrossfadesAndKeepsVirtualSourceGap() throws {
        let left = PCM.tone(seconds: 0.5, sampleRate: sampleRate, freq: 100, amp: 0.5)
        let right = PCM.tone(seconds: 0.5, sampleRate: sampleRate, freq: 100, amp: 0.5, phase: .pi / 2)
        let renderer = TrimRenderer(settings: SmartSpeechSettings())

        let rendered = try renderer.renderMappedSplice(
            left: PCM.buffer(left, sampleRate: sampleRate),
            right: PCM.buffer(right, sampleRate: sampleRate)
        )

        let virtualRightStart = left.count + 1
        #expect(rendered.segments.count == 2)
        #expect(rendered.segments[0].sourceEnd <= left.count)
        #expect(rendered.segments[1].sourceStart >= virtualRightStart)
        #expect(rendered.segments[1].sourceStart > virtualRightStart)
        #expect(PCM.maxAdjacentDelta(PCM.channel(rendered.buffer)) < 0.05)
    }

    @Test("bounded splice snaps both sides of the seam to a zero crossing")
    func boundedSpliceSnapsSeamToZeroCrossing() throws {
        // 1 kHz puts a zero crossing well inside the ±2 ms snap window regardless of edge phase,
        // and neither phase below lands exactly on a crossing — so a real snap must occur, or
        // this degenerates back to the raw-edge bug.
        let left = PCM.tone(seconds: 0.5, sampleRate: sampleRate, freq: 1000, amp: 0.5, phase: 1.3)
        let right = PCM.tone(seconds: 0.5, sampleRate: sampleRate, freq: 1000, amp: 0.5, phase: 0.7)
        let renderer = TrimRenderer(settings: SmartSpeechSettings())

        let rendered = try renderer.renderMappedSplice(
            left: PCM.buffer(left, sampleRate: sampleRate),
            right: PCM.buffer(right, sampleRate: sampleRate)
        )

        let virtualRightStart = left.count + 1
        let crossfadeFrames = Int((15.0 / 1000.0 * sampleRate).rounded())

        // Both sides actually moved off the raw edge, and the sample the snap landed on (or its
        // neighbor) is near zero — proof the seam sits at a real zero crossing, not the raw cut.
        let leftKeep = rendered.segments[0].sourceEnd
        #expect(leftKeep < left.count)
        #expect(min(abs(left[leftKeep - 1]), abs(left[leftKeep])) < 0.1)

        let rightDrop = rendered.segments[1].sourceStart - virtualRightStart - crossfadeFrames
        #expect(rightDrop > 0)
        #expect(min(abs(right[rightDrop - 1]), abs(right[rightDrop])) < 0.1)

        // Segment bookkeeping stays internally consistent: each segment's trimmed span matches
        // its kept source span, spans are contiguous, and they cover the whole rendered buffer —
        // the frames the snap drops shrink the ranges rather than breaking the virtual contract.
        #expect(rendered.segments[0].trimmedStart == 0)
        for segment in rendered.segments {
            #expect(segment.trimmedEnd - segment.trimmedStart == segment.sourceEnd - segment.sourceStart)
        }
        for i in 1..<rendered.segments.count {
            #expect(rendered.segments[i].trimmedStart == rendered.segments[i - 1].trimmedEnd)
        }
        #expect(rendered.segments.last?.trimmedEnd == Int(rendered.buffer.frameLength))
    }
}
