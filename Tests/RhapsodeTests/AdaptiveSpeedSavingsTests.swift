#if PERSONAL_RUBBERBAND
import Testing
@testable import Rhapsode

@Suite("Adaptive playback-speed savings and fallback")
struct AdaptiveSpeedSavingsTests {
    @Test("credits more than four seconds of accelerated playback from consumed tick deltas")
    func creditsConsumedTicks() {
        var accumulator = PlaybackSpeedSavingsAccumulator()
        let ticks = [0.0, 1.0, 2.25, 5.5]
        let savings = ticks.reduce(0.0) { total, outputTime in
            total + accumulator.record(outputSeconds: outputTime, rate: 1.15)
        }

        #expect(abs(savings - (5.5 * (1.15 - 1))) < 0.000_001)
        #expect(savings > 0.0)
    }

    @Test("falls back to the selected user speed after adaptive processing fails")
    func fallsBackToSelectedSpeed() {
        #expect(AdaptiveSpeedPolicy.rateAfterFailure(selectedRate: 1.0) == 1.0)
        #expect(AdaptiveSpeedPolicy.rateAfterFailure(selectedRate: 1.7) == 1.7)
        #expect(AdaptiveSpeedPolicy.rateAfterFailure(selectedRate: 3.0) == 3.0)
    }

    @Test("variable speed credits consumed content, not the selected rate")
    func variableRateSavings() {
        var accumulator = PlaybackSpeedSavingsAccumulator()
        #expect(accumulator.record(contentSeconds: 0, outputSeconds: 0) == 0)
        #expect(abs(accumulator.record(contentSeconds: 2.3, outputSeconds: 2) - 0.3) < 0.000_001)
        #expect(accumulator.record(contentSeconds: 3.3, outputSeconds: 3) == 0)
        #expect(accumulator.record(contentSeconds: 4.3, outputSeconds: 4.5) == 0)
        accumulator.reset()
        #expect(accumulator.record(contentSeconds: 10, outputSeconds: 5) == 0)
    }
}
#endif
