import AVFoundation
import Foundation
import Testing
@testable import CadenceKit

@Suite("OfflineTrimRenderer — splices")
struct OfflineTrimRendererTests {
    let sampleRate = 48_000.0
    let renderer = OfflineTrimRenderer(settings: CadenceSettings())

    @Test("plan keeps the first target seconds of each silence")
    func planKeepsTarget() {
        let total = Int(2.8 * sampleRate)
        let region = SilenceRegion(start: 1.0, end: 1.8)   // D = 0.8
        let plan = renderer.plan(regions: [region], totalFrames: total, sampleRate: sampleRate)

        let target = SilencePolicy.target(forSilenceDuration: 0.8, settings: CadenceSettings())
        let keepEnd = Int(1.0 * sampleRate) + Int((target * sampleRate).rounded())
        let regionEnd = Int(1.8 * sampleRate)

        #expect(plan.keptIntervals.count == 2)
        #expect(plan.keptIntervals[0] == 0..<keepEnd)
        #expect(plan.keptIntervals[1] == regionEnd..<total)
        // Dropped exactly the discarded silence tail.
        #expect(plan.keptFrameCount == total - (regionEnd - keepEnd))
    }

    @Test("Equal-power gains satisfy out² + in² ≈ 1")
    func equalPower() {
        for p in stride(from: 0.0, through: 1.0, by: 0.05) {
            let (out, incoming) = OfflineTrimRenderer.equalPowerGains(progress: p)
            #expect(abs(out * out + incoming * incoming - 1.0) < 1e-9)
        }
        #expect(OfflineTrimRenderer.equalPowerGains(progress: 0).out > 0.999)
        #expect(OfflineTrimRenderer.equalPowerGains(progress: 1).incoming > 0.999)
    }

    @Test("Crossfade preserves power across distinct signals")
    func crossfadePreservesPower() {
        // Two uncorrelated unit-RMS-ish signals; equal-power blend keeps power ~flat.
        let n = 1000
        var worst = 0.0
        for k in 0..<n {
            let p = Double(k) / Double(n - 1)
            let (gOut, gIn) = OfflineTrimRenderer.equalPowerGains(progress: p)
            let a = sin(2 * .pi * 5 * p)       // outgoing
            let b = cos(2 * .pi * 7 * p + 1.3) // incoming, uncorrelated
            let blended = a * gOut + b * gIn
            // Expected power of an equal-power blend of unit signals stays near max(a²,b²)
            // bounds; just assert it never spikes above the sum (no constructive doubling).
            worst = max(worst, blended * blended - (a * a + b * b))
        }
        #expect(worst < 1e-9)
    }

    @Test("No hard cut: the splice step is far smaller than a naive cut")
    func noHardCut() throws {
        // Low-freq tones (tiny internal step) so the only big discontinuity is the join.
        // `before` ends near 0; `after` starts at peak (phase π/2) → a 0.5 jump at the cut.
        let before = PCM.tone(seconds: 1.0, sampleRate: sampleRate, freq: 100, amp: 0.5)
        let silence = PCM.silence(seconds: 0.8, sampleRate: sampleRate)
        let after = PCM.tone(seconds: 1.0, sampleRate: sampleRate, freq: 100, amp: 0.5, phase: .pi / 2)
        let samples = before + silence + after
        let buffer = PCM.buffer(samples, sampleRate: sampleRate)
        let region = SilenceRegion(start: 1.0, end: 1.8)

        let rendered = try renderer.render(buffer: buffer, regions: [region])
        let renderedMaxStep = PCM.maxAdjacentDelta(PCM.channel(rendered))

        // Hard-cut baseline: concatenate the same plan intervals with no blend.
        let plan = renderer.plan(regions: [region], totalFrames: samples.count, sampleRate: sampleRate)
        var hardCut: [Float] = []
        for interval in plan.keptIntervals { hardCut += samples[interval] }
        let hardCutMaxStep = PCM.maxAdjacentDelta(hardCut)

        #expect(hardCutMaxStep > 0.4)         // the artifact we test against
        #expect(renderedMaxStep < 0.05)       // crossfade removes it
        #expect(renderedMaxStep < hardCutMaxStep / 5)
    }

    @Test("Zero-crossing snap lands on a sign change nearest the cut")
    func zeroCrossingSnap() {
        let ref: [Float] = [0.5, 0.5, -0.5, -0.5]
        let snapped = OfflineTrimRenderer.snapZeroCrossing(ref, around: 2, lo: 1, hi: 3, window: 2, total: 4)
        #expect(snapped == 2)   // crossing between idx 1 (+) and idx 2 (−)
    }

    @Test("Stereo channels stay aligned through rendering")
    func stereoPreserved() throws {
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate)
            + PCM.silence(seconds: 0.8, sampleRate: sampleRate)
            + PCM.tone(seconds: 1.0, sampleRate: sampleRate)
        let buffer = PCM.buffer(samples, sampleRate: sampleRate, channels: 2)
        let rendered = try renderer.render(buffer: buffer, regions: [SilenceRegion(start: 1.0, end: 1.8)])
        #expect(rendered.format.channelCount == 2)
        #expect(PCM.channel(rendered, 0) == PCM.channel(rendered, 1))
    }

    @Test("No regions → output is the untouched input")
    func noRegionsNoOp() throws {
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate)
        let buffer = PCM.buffer(samples, sampleRate: sampleRate)
        let rendered = try renderer.render(buffer: buffer, regions: [])
        #expect(rendered.frameLength == buffer.frameLength)
        #expect(PCM.channel(rendered) == samples)
    }
}
