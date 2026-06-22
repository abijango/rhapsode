import Foundation
import Testing
@testable import CadenceKit

@Suite("CadenceSettings")
struct CadenceSettingsTests {
    @Test("Defaults match the spec")
    func defaults() {
        let s = CadenceSettings()
        #expect(s.minSilenceDuration == 0.28)
        #expect(s.minKeptSilence == 0.18)
        #expect(s.residualSlope == 0.12)
        #expect(s.thresholdMarginDb == 8.0)
        #expect(s.edgeGuardMs == 40)
        #expect(s.crossfadeMs == 15)
    }

    @Test("Presets keep progressively less silence (default ≥ more ≥ aggressive)")
    func presetProgression() {
        let presets = [CadenceSettings(preset: .default),
                       CadenceSettings(preset: .more),
                       CadenceSettings(preset: .aggressive)]
        // For any silence eligible under all three, the kept target must be non-increasing.
        var D = 0.30
        while D <= 5.0 {
            let targets = presets.map { SilencePolicy.target(forSilenceDuration: D, settings: $0) }
            #expect(targets[0] >= targets[1] - 1e-12)
            #expect(targets[1] >= targets[2] - 1e-12)
            D += 0.1
        }
    }

    @Test("Default preset equals the bare defaults")
    func defaultPresetMatches() {
        #expect(CadenceSettings(preset: .default) == CadenceSettings())
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = CadenceSettings(minSilenceDuration: 0.3, minKeptSilence: 0.2,
                                       residualSlope: 0.15, thresholdMarginDb: 9,
                                       edgeGuardMs: 35, crossfadeMs: 18)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CadenceSettings.self, from: data)
        #expect(decoded == original)
    }
}
