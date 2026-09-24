#if PERSONAL_RUBBERBAND
import Foundation
import Testing
@testable import Rhapsode

@Suite("Adaptive playback-speed timeline and stream")
struct AdaptiveSpeedPlaybackTests {
    @Test("maps variable-rate frames exactly across a speech-to-music boundary")
    func mapsVariableRateBoundary() {
        let speechContentSeconds = 4.0
        let musicContentSeconds = 3.0
        let speechRate = 1.15
        let speechPlaybackSeconds = speechContentSeconds / speechRate
        let playbackDuration = speechPlaybackSeconds + musicContentSeconds
        let contentDuration = speechContentSeconds + musicContentSeconds
        let map = PlaybackTimeMap(
            checkpoints: [
                .init(playbackTime: 0, contentTime: 0),
                .init(playbackTime: speechPlaybackSeconds, contentTime: speechContentSeconds)
            ],
            playbackDuration: playbackDuration,
            contentDuration: contentDuration
        )

        #expect(abs(map.contentTime(forPlaybackTime: speechPlaybackSeconds) - 4.0) < 0.000_001)
        #expect(map.contentTime(forPlaybackTime: speechPlaybackSeconds - 0.01) < 4.0)
        #expect(map.contentTime(forPlaybackTime: speechPlaybackSeconds + 0.01) > 4.0)
        #expect(abs(map.playbackTime(forContentTime: 4.0) - speechPlaybackSeconds) < 0.000_001)
        #expect(map.contentTime(forPlaybackTime: playbackDuration) == contentDuration)
    }

    @Test("includes the flushed Rubber Band tail in the final frame and time map")
    func mapsFlushedTail() throws {
        let sampleRate = 48_000.0
        let firstInput = tone(frames: 19_200, sampleRate: sampleRate)
        let secondInput = tone(frames: 28_800, sampleRate: sampleRate)
        let firstStream = try RubberBandStream(
            sampleRate: sampleRate,
            channelCount: 1,
            playbackRate: 1.15
        )
        let firstProcessOutput = try firstStream.process(firstInput)
        let firstTail = try firstStream.finish()
        let firstOutput = firstProcessOutput + firstTail
        let secondStream = try RubberBandStream(
            sampleRate: sampleRate,
            channelCount: 1,
            playbackRate: 1.0
        )
        let secondProcessOutput = try secondStream.process(secondInput)
        let secondTail = try secondStream.finish()
        let secondOutput = secondProcessOutput + secondTail
        let firstPlaybackSeconds = Double(firstOutput.count) / sampleRate
        let playbackDuration = firstPlaybackSeconds + Double(secondOutput.count) / sampleRate
        let contentDuration = Double(firstInput.count + secondInput.count) / sampleRate
        let map = PlaybackTimeMap(
            checkpoints: [
                .init(playbackTime: 0, contentTime: 0),
                .init(playbackTime: firstPlaybackSeconds, contentTime: Double(firstInput.count) / sampleRate)
            ],
            playbackDuration: playbackDuration,
            contentDuration: contentDuration
        )

        #expect(!firstOutput.isEmpty)
        #expect(!secondOutput.isEmpty)
        #expect(firstStream.pushProgress.last?.inputFrames == 0)
        #expect(firstStream.pushProgress.last?.cumulativeOutputFrames == firstOutput.count)
        #expect(firstStream.discardedTailPaddingFrames > 0)
        #expect(abs(Double(firstOutput.count) - Double(firstInput.count) / 1.15) < sampleRate * 0.04)
        #expect(abs(Double(secondOutput.count) - Double(secondInput.count)) < sampleRate * 0.04)
        #expect(map.contentTime(forPlaybackTime: playbackDuration) == contentDuration)
    }

    private func tone(frames: Int, sampleRate: Double) -> [Float] {
        (0 ..< frames).map { frame in
            Float(0.2 * sin(2 * .pi * 440 * Double(frame) / sampleRate))
        }
    }
}
#endif
