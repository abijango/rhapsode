import Testing
@testable import Rhapsode

@Suite("PlaybackTimeMap — playback and content timelines")
struct PlaybackTimeMapTests {
    @Test("interpolates exact playback-to-content checkpoints in both directions")
    func interpolatesBetweenCheckpoints() {
        let map = PlaybackTimeMap(
            checkpoints: [
                .init(playbackTime: 0, contentTime: 0),
                .init(playbackTime: 2, contentTime: 2.5),
                .init(playbackTime: 4, contentTime: 5)
            ],
            playbackDuration: 4,
            contentDuration: 5
        )

        #expect(map.contentTime(forPlaybackTime: 1) == 1.25)
        #expect(map.contentTime(forPlaybackTime: 3) == 3.75)
        #expect(map.playbackTime(forContentTime: 1.25) == 1)
        #expect(map.playbackTime(forContentTime: 3.75) == 3)
    }

    @Test("clamps playback and content lookups to their respective timeline bounds")
    func clampsToTimelineBounds() {
        let map = PlaybackTimeMap(
            checkpoints: [
                .init(playbackTime: 0, contentTime: 0),
                .init(playbackTime: 2, contentTime: 3)
            ],
            playbackDuration: 2,
            contentDuration: 3
        )

        #expect(map.contentTime(forPlaybackTime: -4) == 0)
        #expect(map.contentTime(forPlaybackTime: 20) == 3)
        #expect(map.playbackTime(forContentTime: -4) == 0)
        #expect(map.playbackTime(forContentTime: 20) == 2)
    }

    @Test("composes with the existing content-to-source trim map for seeking")
    func composesWithContentToSourceMap() {
        let contentToSource = SmartSpeechTimelineMap(
            points: [
                .init(source: 0, trimmed: 0),
                .init(source: 10, trimmed: 10),
                .init(source: 20, trimmed: 10),
                .init(source: 30, trimmed: 20),
                .init(source: 40, trimmed: 30)
            ],
            sourceDuration: 40,
            trimmedDuration: 30
        )
        let playbackToContent = PlaybackTimeMap(
            checkpoints: [
                .init(playbackTime: 0, contentTime: 0),
                .init(playbackTime: 8, contentTime: 20)
            ],
            playbackDuration: 8,
            contentDuration: 20
        )

        let targetSourceTime = 25.0
        let targetContentTime = contentToSource.toTrimmed(targetSourceTime)
        let targetPlaybackTime = playbackToContent.playbackTime(forContentTime: targetContentTime)
        let resolvedContentTime = playbackToContent.contentTime(forPlaybackTime: targetPlaybackTime)

        #expect(targetContentTime == 15)
        #expect(targetPlaybackTime == 6)
        #expect(contentToSource.toSource(resolvedContentTime) == targetSourceTime)
    }
}
