import Foundation
import Testing
@testable import Rhapsode

@Suite("Cross-device SmartSpeech totals")
struct DeviceStatsTotalsTests {
    @Test("adds each device's contribution once")
    func combinesDevices() {
        let records = [
            DeviceStatsRecord(deviceId: "phone", savedSeconds: 600,
                              playedSeconds: 3_600, updatedAt: .now),
            DeviceStatsRecord(deviceId: "tablet", savedSeconds: 720,
                              playedSeconds: 4_200, updatedAt: .now)
        ]
        let totals = DeviceStatsTotals(records: records, deviceId: "phone",
                                       mySavedSeconds: 600, myPlayedSeconds: 3_600)

        #expect(totals.savedSeconds == 1_320)
        #expect(totals.playedSeconds == 7_800)
    }

    @Test("unuploaded local playback and a newer local-device backup merge independently")
    func reconcilesMyDevice() {
        let records = [
            DeviceStatsRecord(deviceId: "phone", savedSeconds: 750,
                              playedSeconds: 3_600, updatedAt: .now),
            DeviceStatsRecord(deviceId: "tablet", savedSeconds: 720,
                              playedSeconds: 4_200, updatedAt: .now)
        ]
        let totals = DeviceStatsTotals(records: records, deviceId: "phone",
                                       mySavedSeconds: 600, myPlayedSeconds: 3_900)

        #expect(totals.mySavedSeconds == 750)
        #expect(totals.myPlayedSeconds == 3_900)
        #expect(totals.savedSeconds == 1_470)
        #expect(totals.playedSeconds == 8_100)
    }

    @Test("missing remote record retains the live local contribution")
    func retainsUnuploadedLocal() {
        let totals = DeviceStatsTotals(records: [
            DeviceStatsRecord(deviceId: "tablet", savedSeconds: 720,
                              playedSeconds: 4_200, updatedAt: .now)
        ], deviceId: "phone", mySavedSeconds: 600, myPlayedSeconds: 3_600)

        #expect(totals.savedSeconds == 1_320)
        #expect(totals.playedSeconds == 7_800)
    }
}
