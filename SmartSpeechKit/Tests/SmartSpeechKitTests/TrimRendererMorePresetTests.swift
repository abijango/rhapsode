import AVFoundation
import Foundation
import Testing
@testable import SmartSpeechKit

/// More (the middle tier) detects shorter gaps than Default. That is the difference that
/// shows up as "audio crash on More, not Default" — more joints, shorter kept islands.
@Suite("TrimRenderer — More-tier density")
struct TrimRendererMorePresetTests {
    let sampleRate = 48_000.0

    @Test("More detects ~0.33s gaps that Default leaves alone")
    func moreDetectsShorterGaps() {
        var samples: [Float] = PCM.tone(seconds: 0.6, sampleRate: sampleRate)
        for _ in 0..<8 {
            // After 38–40ms edge guards, 0.33s quiet is ≥ More's 0.24s floor and < Default's 0.28s.
            samples += PCM.silence(seconds: 0.33, sampleRate: sampleRate)
            samples += PCM.tone(seconds: 0.35, sampleRate: sampleRate)
        }
        let defaultRegions = SilenceAnalyzer(settings: SmartSpeechSettings(preset: .default))
            .analyze(monoSamples: samples, sampleRate: sampleRate).regions
        let moreRegions = SilenceAnalyzer(settings: SmartSpeechSettings(preset: .more))
            .analyze(monoSamples: samples, sampleRate: sampleRate).regions
        #expect(moreRegions.count > defaultRegions.count)
        #expect(moreRegions.count >= 4)
    }

    @Test("Dense More-like silences still render without inverted intervals")
    func denseMoreSilencesRender() throws {
        var samples: [Float] = PCM.tone(seconds: 0.4, sampleRate: sampleRate)
        var regions: [SilenceRegion] = []
        var t = 0.4
        for _ in 0..<20 {
            let silence = 0.26
            regions.append(SilenceRegion(start: t, end: t + silence))
            samples += PCM.silence(seconds: silence, sampleRate: sampleRate)
            t += silence
            let speech = 0.04
            samples += PCM.tone(seconds: speech, sampleRate: sampleRate, freq: 220)
            t += speech
        }
        samples += PCM.tone(seconds: 0.4, sampleRate: sampleRate)
        let buffer = PCM.buffer(samples, sampleRate: sampleRate)
        let renderer = TrimRenderer(settings: SmartSpeechSettings(preset: .more))
        let plan = renderer.plan(regions: regions, totalFrames: samples.count, sampleRate: sampleRate)
        for interval in plan.keptIntervals {
            #expect(interval.lowerBound <= interval.upperBound)
            #expect(interval.lowerBound >= 0)
            #expect(interval.upperBound <= samples.count)
        }
        let rendered = try renderer.renderMapped(buffer: buffer, regions: regions)
        #expect(rendered.buffer.frameLength > 0)
        #expect(Int(rendered.buffer.frameLength) <= samples.count)
        for seg in rendered.segments {
            #expect(seg.sourceStart <= seg.sourceEnd)
            #expect(seg.trimmedStart <= seg.trimmedEnd)
        }
    }

    @Test("Chunk-edge sliver of a long silence does not produce a zero-length output")
    func chunkEdgeSliverRenders() throws {
        let samples = PCM.tone(seconds: 0.8, sampleRate: sampleRate)
            + PCM.silence(seconds: 0.05, sampleRate: sampleRate)
        let buffer = PCM.buffer(samples, sampleRate: sampleRate)
        let region = SilenceRegion(start: 0.8, end: 0.85)
        let renderer = TrimRenderer(settings: SmartSpeechSettings(preset: .more))
        let rendered = try renderer.renderMapped(buffer: buffer, regions: [region])
        #expect(rendered.buffer.frameLength > 0)
    }
}
