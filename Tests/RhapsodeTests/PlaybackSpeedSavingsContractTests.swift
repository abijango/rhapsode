import Foundation
import Testing
@testable import Rhapsode

@Suite("Playback-speed savings contracts")
struct PlaybackSpeedSavingsContractTests {
    @Test("per-book speed savings stay separate from SmartSpeech savings")
    func bookCountersRemainIndependent() {
        let audiobook = Audiobook(
            title: "Book",
            sourcePath: "book.m4b",
            smartSpeechSavedSeconds: 120,
            mySmartSpeechSavedSeconds: 80
        )
        audiobook.playbackSpeedSavedSeconds = 45
        audiobook.myPlaybackSpeedSavedSeconds = 30

        #expect(audiobook.smartSpeechSavedSeconds == 120)
        #expect(audiobook.mySmartSpeechSavedSeconds == 80)
        #expect(audiobook.playbackSpeedSavedSeconds == 45)
        #expect(audiobook.myPlaybackSpeedSavedSeconds == 30)
    }

    @Test("legacy device totals decode with zero speed savings")
    func legacyDeviceStatsDecodeWithoutSpeedSavings() throws {
        let json = Data(
            #"{"deviceId":"phone","savedSeconds":120,"playedSeconds":600,"updatedAt":"2026-01-01T00:00:00Z"}"#.utf8
        )

        let record = try PlaybackProgress.decoder.decode(DeviceStatsRecord.self, from: json)

        #expect(record.speedSavedSeconds == 0)
        #expect(record.savedSeconds == 120)
        #expect(record.playedSeconds == 600)
    }

    @Test("book contribution speed savings round-trip and legacy data defaults to zero")
    func bookContributionSpeedSavingsCodable() throws {
        let legacyJSON = Data(
            #"{"deviceId":"phone","key":"book.m4b","kind":"audiobooks","listenedSeconds":600,"savedSeconds":120,"updatedAt":"2026-01-01T00:00:00Z"}"#.utf8
        )
        let legacy = try PlaybackProgress.decoder.decode(DeviceBookContribution.self, from: legacyJSON)
        #expect((legacy.speedSavedSeconds ?? 0) == 0)

        var contribution = legacy
        contribution.speedSavedSeconds = 45
        let encoded = try PlaybackProgress.encoder.encode(contribution)
        let decoded = try PlaybackProgress.decoder.decode(DeviceBookContribution.self, from: encoded)

        #expect(decoded.speedSavedSeconds == 45)
    }

    @Test("device speed totals use independent per-device maxima")
    func speedTotalsFoldDevicesIndependently() {
        let records = [
            statsRecord(deviceId: "phone", saved: 100, played: 300, speedSaved: 15),
            statsRecord(deviceId: "phone", saved: 120, played: 250, speedSaved: 20),
            statsRecord(deviceId: "tablet", saved: 50, played: 100, speedSaved: 8),
            statsRecord(deviceId: "watch", saved: 80, played: 200, speedSaved: 30)
        ]
        let totals = DeviceStatsTotals(
            records: records,
            deviceId: "phone",
            mySavedSeconds: 110,
            myPlayedSeconds: 500,
            mySpeedSavedSeconds: 18
        )

        #expect(totals.mySpeedSavedSeconds == 20)
        #expect(totals.speedSavedSeconds == 58)
        #expect(totals.mySavedSeconds == 120)
        #expect(totals.savedSeconds == 250)
        #expect(totals.myPlayedSeconds == 500)
        #expect(totals.playedSeconds == 800)
    }

    @Test("lifetime speed savings remain additive to, not folded into, SmartSpeech savings")
    func lifetimeCountersRemainSeparate() {
        let previousSmartSpeechTotal = SmartSpeechStats.totalSavedSeconds
        let previousMySmartSpeechTotal = SmartSpeechStats.mySavedSeconds
        let previousSpeedTotal = SmartSpeechStats.totalSpeedSavedSeconds
        let previousMySpeedTotal = SmartSpeechStats.mySpeedSavedSeconds
        defer {
            SmartSpeechStats.totalSavedSeconds = previousSmartSpeechTotal
            SmartSpeechStats.mySavedSeconds = previousMySmartSpeechTotal
            SmartSpeechStats.totalSpeedSavedSeconds = previousSpeedTotal
            SmartSpeechStats.mySpeedSavedSeconds = previousMySpeedTotal
        }

        SmartSpeechStats.totalSavedSeconds = 1_200
        SmartSpeechStats.mySavedSeconds = 700
        SmartSpeechStats.totalSpeedSavedSeconds = 240
        SmartSpeechStats.mySpeedSavedSeconds = 140

        #expect(SmartSpeechStats.totalSavedSeconds == 1_200)
        #expect(SmartSpeechStats.mySavedSeconds == 700)
        #expect(SmartSpeechStats.totalSpeedSavedSeconds == 240)
        #expect(SmartSpeechStats.mySpeedSavedSeconds == 140)
        #expect(SmartSpeechStats.totalSavedSeconds + SmartSpeechStats.totalSpeedSavedSeconds == 1_440)
        #expect(SmartSpeechStats.mySavedSeconds + SmartSpeechStats.mySpeedSavedSeconds == 840)
    }

    private func statsRecord(
        deviceId: String,
        saved: TimeInterval,
        played: TimeInterval,
        speedSaved: TimeInterval
    ) -> DeviceStatsRecord {
        var record = DeviceStatsRecord(
            deviceId: deviceId,
            savedSeconds: saved,
            playedSeconds: played,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        record.speedSavedSeconds = speedSaved
        return record
    }
}
