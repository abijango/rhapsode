import Foundation
import Testing
@testable import CadenceKit

@Suite("TrimReport")
struct TrimReportTests {
    @Test("Savings are computed from measured durations")
    func savings() {
        let report = TrimReport(originalDuration: 100, trimmedDuration: 85,
                                regions: [], settings: CadenceSettings(),
                                noiseFloorDb: -60, sampleRate: 48_000)
        #expect(report.savedSeconds == 15)
        #expect(abs(report.savedPercent - 15) < 1e-9)
    }

    @Test("meanRegionSaving is the mean of (D − target)")
    func meanRegionSaving() {
        let settings = CadenceSettings()
        let regions = [SilenceRegion(start: 0, end: 2.0), SilenceRegion(start: 3, end: 4.0)] // D = 2.0, 1.0
        let report = TrimReport(originalDuration: 10, trimmedDuration: 8,
                                regions: regions, settings: settings,
                                noiseFloorDb: -60, sampleRate: 48_000)
        let s1 = 2.0 - SilencePolicy.target(forSilenceDuration: 2.0, settings: settings)
        let s2 = 1.0 - SilencePolicy.target(forSilenceDuration: 1.0, settings: settings)
        #expect(report.regionCount == 2)
        #expect(abs(report.meanRegionSaving - (s1 + s2) / 2) < 1e-9)
    }

    @Test("Zero original duration does not divide by zero")
    func emptyInput() {
        let report = TrimReport(originalDuration: 0, trimmedDuration: 0,
                                regions: [], settings: CadenceSettings(),
                                noiseFloorDb: -160, sampleRate: 48_000)
        #expect(report.savedPercent == 0)
        #expect(report.meanRegionSaving == 0)
    }

    @Test("JSON round-trip")
    func codable() throws {
        let report = TrimReport(originalDuration: 200, trimmedDuration: 180,
                                regions: [SilenceRegion(start: 1, end: 2)],
                                settings: CadenceSettings(), noiseFloorDb: -55, sampleRate: 44_100)
        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(TrimReport.self, from: data)
        #expect(decoded.savedSeconds == report.savedSeconds)
        #expect(decoded.regionCount == report.regionCount)
        #expect(decoded.settings == report.settings)
        #expect(decoded.sampleRate == report.sampleRate)
    }
}
