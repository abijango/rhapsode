#if PERSONAL_RUBBERBAND
import Foundation
import Testing
@testable import Rhapsode

@Suite("RubberBandStream — continuous playback-rate PCM")
struct RubberBandStreamTests {
    private let sampleRate = 48_000.0

    @Test("preserves the requested duration across chunks and drains the padded tail")
    func preservesDurationAndDrainsTail() throws {
        let rate = 1.25
        let input = tone(seconds: 0.9, frequency: 440)
        let split = input.count / 2 + 3_123
        let stream = try RubberBandStream(
            sampleRate: sampleRate,
            channelCount: 1,
            playbackRate: rate
        )

        let firstOutput = try stream.process(Array(input[..<split]))
        let secondOutput = try stream.process(Array(input[split...]))
        let tailOutput = try stream.finish()
        let output = firstOutput + secondOutput + tailOutput
        let expectedFrames = Double(input.count) / rate
        let durationToleranceFrames = Int(sampleRate * 0.04)
        let edgeWindowFrames = Int(sampleRate * 0.08)

        #expect(abs(Double(output.count) - expectedFrames) <= Double(durationToleranceFrames))
        #expect(rms(Array(output.prefix(edgeWindowFrames))) > 0.03)
        #expect(rms(Array(output.suffix(edgeWindowFrames))) > 0.03)
        #expect(maxAdjacentDelta(output) < 0.15)
        #expect(output.allSatisfy { sample in sample.isFinite })
    }

    private func tone(seconds: Double, frequency: Double) -> [Float] {
        let frameCount = Int(sampleRate * seconds)
        return (0 ..< frameCount).map { frame in
            Float(0.25 * sin(2 * .pi * frequency * Double(frame) / sampleRate + 0.4))
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        return sqrt(meanSquare)
    }

    private func maxAdjacentDelta(_ samples: [Float]) -> Double {
        zip(samples, samples.dropFirst()).reduce(0) {
            max($0, abs(Double($1.1 - $1.0)))
        }
    }
}
#endif
