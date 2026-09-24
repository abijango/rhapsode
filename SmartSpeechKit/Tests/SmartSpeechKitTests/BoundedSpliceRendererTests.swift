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
}
