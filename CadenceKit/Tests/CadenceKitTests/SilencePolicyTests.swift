import Testing
@testable import CadenceKit

@Suite("SilencePolicy — D → target")
struct SilencePolicyTests {
    let settings = CadenceSettings()

    @Test("Silences below minSilenceDuration are untouched (target == D)")
    func untouchedBelowFloor() {
        for D in [0.0, 0.05, 0.15, 0.27, 0.279] {
            #expect(SilencePolicy.target(forSilenceDuration: D, settings: settings) == D)
        }
    }

    @Test("At the eligibility threshold, target collapses to minKeptSilence")
    func atThreshold() {
        let t = SilencePolicy.target(forSilenceDuration: settings.minSilenceDuration, settings: settings)
        #expect(abs(t - settings.minKeptSilence) < 1e-9)
    }

    @Test("Proportional value matches the formula")
    func proportional() {
        // D = 2.0 → 0.18 + (2.0 − 0.28) * 0.12 = 0.3864
        let t = SilencePolicy.target(forSilenceDuration: 2.0, settings: settings)
        #expect(abs(t - 0.3864) < 1e-9)
    }

    @Test("target ≤ D and target ≥ minKeptSilence once eligible")
    func boundsHold() {
        var D = settings.minSilenceDuration
        while D <= 10 {
            let t = SilencePolicy.target(forSilenceDuration: D, settings: settings)
            #expect(t <= D + 1e-12)
            #expect(t >= settings.minKeptSilence - 1e-12)
            D += 0.05
        }
    }

    // Monotonicity holds within the trimming regime (D ≥ minSilenceDuration). There is an
    // intentional downward step at the threshold: a silence just under it is kept whole,
    // while one just over it becomes eligible and collapses toward minKeptSilence.
    @Test("Monotonic non-decreasing once eligible")
    func monotonic() {
        var previous = -1.0
        var D = settings.minSilenceDuration
        while D <= 10 {
            let t = SilencePolicy.target(forSilenceDuration: D, settings: settings)
            #expect(t >= previous - 1e-12)
            previous = t
            D += 0.01
        }
    }

    @Test("Intentional downward step at the eligibility threshold")
    func stepAtThreshold() {
        let justUnder = SilencePolicy.target(forSilenceDuration: 0.279, settings: settings)
        let justOver = SilencePolicy.target(forSilenceDuration: 0.281, settings: settings)
        #expect(justUnder == 0.279)                 // untouched
        #expect(abs(justOver - settings.minKeptSilence) < 0.001)   // collapses to the floor
        #expect(justOver < justUnder)               // the step is downward, by design
    }

    @Test("Upper clamp: proportional value never exceeds D")
    func upperClamp() {
        // minKeptSilence near D forces proportional > D → must clamp to D.
        let tight = CadenceSettings(minSilenceDuration: 0.28, minKeptSilence: 0.5, residualSlope: 0.12)
        let t = SilencePolicy.target(forSilenceDuration: 0.30, settings: tight)
        #expect(abs(t - 0.30) < 1e-9)
    }
}
