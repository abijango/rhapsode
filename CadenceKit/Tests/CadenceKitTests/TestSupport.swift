import AVFoundation
import Foundation

/// Synthetic-PCM builders for golden tests. Deterministic — no randomness — so detected
/// regions are stable across runs.
enum PCM {
    /// A sine tone. `phase` lets a segment start at a chosen amplitude (e.g. π/2 → starts at peak).
    static func tone(seconds: Double, sampleRate: Double, freq: Double = 1000,
                     amp: Float = 0.5, phase: Double = 0) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { amp * Float(sin(2 * .pi * freq * Double($0) / sampleRate + phase)) }
    }

    /// `amp == 0` → true digital silence; otherwise a quiet high-freq "room tone" floor
    /// (deterministic, for the noise-floor-variant test).
    static func silence(seconds: Double, sampleRate: Double, amp: Float = 0, freq: Double = 7000) -> [Float] {
        let n = Int(seconds * sampleRate)
        guard amp != 0 else { return [Float](repeating: 0, count: n) }
        return (0..<n).map { amp * Float(sin(2 * .pi * freq * Double($0) / sampleRate)) }
    }

    /// Build a deinterleaved float buffer; every channel gets the same samples.
    static func buffer(_ samples: [Float], sampleRate: Double, channels: Int = 1) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels))!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for ch in 0..<channels {
            samples.withUnsafeBufferPointer { buffer.floatChannelData![ch].update(from: $0.baseAddress!, count: samples.count) }
        }
        return buffer
    }

    static func channel(_ buffer: AVAudioPCMBuffer, _ ch: Int = 0) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(buffer.frameLength)))
    }

    static func maxAdjacentDelta(_ s: [Float]) -> Float {
        guard s.count > 1 else { return 0 }
        var m: Float = 0
        for i in 1..<s.count { m = max(m, abs(s[i] - s[i - 1])) }
        return m
    }
}
