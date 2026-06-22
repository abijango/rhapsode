import Foundation
import Testing
@testable import CadenceKit

@Suite("SilenceAnalyzer — golden synthetic PCM")
struct SilenceAnalyzerTests {
    let sampleRate = 48_000.0
    let analyzer = SilenceAnalyzer(settings: CadenceSettings())

    // tone(1s) | silence(0.8s) | tone(1s). Raw silence ≈ [1.0, 1.8]; after 40 ms edge
    // guard each side ≈ [1.04, 1.76]. Tolerance covers windowing (~±1 window + guard).
    @Test("Detects a single clear silence, edge-guarded")
    func singleSilence() {
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate)
            + PCM.silence(seconds: 0.8, sampleRate: sampleRate)
            + PCM.tone(seconds: 1.0, sampleRate: sampleRate)
        let result = analyzer.analyze(monoSamples: samples, sampleRate: sampleRate)
        #expect(result.regions.count == 1)
        let r = result.regions[0]
        #expect(abs(r.start - 1.04) < 0.06)
        #expect(abs(r.end - 1.76) < 0.06)
    }

    @Test("Silence shorter than minSilenceDuration is discarded")
    func shortSilenceIgnored() {
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate)
            + PCM.silence(seconds: 0.15, sampleRate: sampleRate)
            + PCM.tone(seconds: 1.0, sampleRate: sampleRate)
        #expect(analyzer.analyze(monoSamples: samples, sampleRate: sampleRate).regions.isEmpty)
    }

    @Test("Quiet narrator still detected via adaptive floor")
    func quietSpeaker() {
        // Tone at −40 dBFS; absolute thresholds would miss it, the relative floor does not.
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate, amp: 0.01)
            + PCM.silence(seconds: 0.8, sampleRate: sampleRate)
            + PCM.tone(seconds: 1.0, sampleRate: sampleRate, amp: 0.01)
        #expect(analyzer.analyze(monoSamples: samples, sampleRate: sampleRate).regions.count == 1)
    }

    @Test("Detected over a non-zero room-tone floor")
    func noiseFloorVariant() {
        // "Silence" is quiet tonal room tone (≈ −60 dBFS), speech well above it.
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate, amp: 0.5)
            + PCM.silence(seconds: 0.8, sampleRate: sampleRate, amp: 0.001)
            + PCM.tone(seconds: 1.0, sampleRate: sampleRate, amp: 0.5)
        #expect(analyzer.analyze(monoSamples: samples, sampleRate: sampleRate).regions.count == 1)
    }

    @Test("Continuous tone yields no regions (no false positive)")
    func continuousTone() {
        let samples = PCM.tone(seconds: 2.0, sampleRate: sampleRate)
        #expect(analyzer.analyze(monoSamples: samples, sampleRate: sampleRate).regions.isEmpty)
    }

    @Test("Edge guard shrinks the region inward by ~2 × edgeGuardMs")
    func edgeGuardShrinks() {
        let samples = PCM.tone(seconds: 1.0, sampleRate: sampleRate)
            + PCM.silence(seconds: 1.0, sampleRate: sampleRate)
            + PCM.tone(seconds: 1.0, sampleRate: sampleRate)
        let r = analyzer.analyze(monoSamples: samples, sampleRate: sampleRate).regions[0]
        // Raw silence ≈ 1.0s; guarded ≈ 1.0 − 2*0.04 = 0.92s.
        #expect(abs(r.duration - 0.92) < 0.06)
    }
}
