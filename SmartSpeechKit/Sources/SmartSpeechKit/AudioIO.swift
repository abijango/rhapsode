import Accelerate
import AVFoundation
import Foundation

public enum AudioIOError: Error, CustomStringConvertible {
    case tooLong(seconds: Double, limit: Double)
    case startBeyondEnd(start: Double, length: Double)
    case allocationFailed
    case noAudioTrack
    case undecodable(underlying: Error)

    public var description: String {
        switch self {
        case let .tooLong(s, limit):
            return "Selected window is \(Int(s))s; the harness decodes it into memory and caps at \(Int(limit))s. Use --start/--duration to pick a shorter section (the spec targets 3–5 min)."
        case let .startBeyondEnd(start, length):
            return "--start \(Int(start))s is past the end of the \(Int(length))s file."
        case .allocationFailed:
            return "Could not allocate a PCM buffer for the decoded audio."
        case .noAudioTrack:
            return "No decodable audio track found (file may be DRM-protected)."
        case let .undecodable(err):
            return "Could not decode audio: \(err)"
        }
    }
}

/// Decode/downmix/encode — the only place SmartSpeechKit touches the file system or codecs.
/// Decoding produces a standard float32 *deinterleaved* buffer; the analyzer consumes a
/// mono downmix while the renderer keeps every channel.
public enum AudioIO {
    /// Decode an audio file (or a window of it) to an in-memory float32 deinterleaved buffer.
    ///
    /// Tries `AVAudioFile` first (handles `.m4b`/`.m4a`/`.mp3`/`.wav`); falls back to
    /// `AVAssetReader` for anything it won't open. The decoded window is held in memory, so
    /// `maxSeconds` guards against decoding a multi-hour book — pass `startSeconds`/
    /// `durationSeconds` to pull a short section straight out of a long file.
    public static func decode(_ url: URL,
                              startSeconds: Double = 0,
                              durationSeconds: Double? = nil,
                              maxSeconds: Double = 3600) throws -> AVAudioPCMBuffer {
        if let file = try? AVAudioFile(forReading: url) {
            let format = file.processingFormat          // standard float32, deinterleaved
            let sampleRate = format.sampleRate
            let startFrame = AVAudioFramePosition(max(0, startSeconds) * sampleRate)
            guard startFrame < file.length else {
                throw AudioIOError.startBeyondEnd(start: startSeconds, length: Double(file.length) / sampleRate)
            }
            let available = file.length - startFrame
            let wanted = durationSeconds.map { AVAudioFramePosition(max(0, $0) * sampleRate) } ?? available
            let frames = min(wanted, available)
            let duration = Double(frames) / sampleRate
            guard duration <= maxSeconds else {
                throw AudioIOError.tooLong(seconds: duration, limit: maxSeconds)
            }
            guard frames > 0, let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frames)
            ) else { throw AudioIOError.allocationFailed }
            file.framePosition = startFrame
            try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
            return buffer
        }
        return try decodeWithAssetReader(url, startSeconds: startSeconds,
                                         durationSeconds: durationSeconds, maxSeconds: maxSeconds)
    }

    /// Average all channels into a single `[Float]` for analysis.
    public static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        var mono: [Float] = []
        downmixToMono(into: &mono, from: buffer)
        return mono
    }

    /// Downmix into `mono`, reusing its storage when `mono.count == frameLength`. When the
    /// source is already mono, copies channel 0 directly (no extra `[Float]` allocation).
    public static func downmixToMono(into mono: inout [Float], from buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else {
            mono.removeAll(keepingCapacity: false)
            return
        }
        let channelCount = Int(buffer.format.channelCount)
        if mono.count != frames {
            mono = [Float](repeating: 0, count: frames)
        } else {
            vDSP_vclr(&mono, 1, vDSP_Length(frames))
        }
        if channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                guard let dstBase = dst.baseAddress else { return }
                memcpy(dstBase, channels[0], frames * MemoryLayout<Float>.size)
            }
            return
        }
        var scale = 1.0 / Float(channelCount)
        mono.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            vDSP_vsmul(channels[0], 1, &scale, dstBase, 1, vDSP_Length(frames))
            for ch in 1..<channelCount {
                vDSP_vsma(channels[ch], 1, &scale, dstBase, 1, dstBase, 1, vDSP_Length(frames))
            }
        }
    }

    /// Write a buffer to a 16-bit PCM WAV (broadly playable; AVAudioFile converts
    /// the float processing format to int16 on disk).
    public static func writeWAV(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let format = buffer.format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    // MARK: - AVAssetReader fallback

    private static func decodeWithAssetReader(_ url: URL, startSeconds: Double,
                                              durationSeconds: Double?, maxSeconds: Double) throws -> AVAudioPCMBuffer {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let fmtDesc = track.formatDescriptions.first else {
            throw AudioIOError.noAudioTrack
        }
        let cmFormat = fmtDesc as! CMAudioFormatDescription
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cmFormat)?.pointee else {
            throw AudioIOError.noAudioTrack
        }
        let sampleRate = asbd.mSampleRate
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameLimit = Int(maxSeconds * sampleRate) * max(channelCount, 1)

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw AudioIOError.undecodable(underlying: error) }

        // Restrict decoding to the requested window.
        if startSeconds > 0 || durationSeconds != nil {
            let scale: CMTimeScale = 600
            let start = CMTime(seconds: max(0, startSeconds), preferredTimescale: scale)
            let length = CMTime(seconds: durationSeconds ?? maxSeconds, preferredTimescale: scale)
            reader.timeRange = CMTimeRange(start: start, duration: length)
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,   // interleaved → contiguous copy
        ])
        reader.add(output)
        reader.startReading()

        var interleaved: [Float] = []
        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                        totalLengthOut: &length, dataPointerOut: &dataPtr)
            if let dataPtr {
                let floatCount = length / MemoryLayout<Float>.size
                dataPtr.withMemoryRebound(to: Float.self, capacity: floatCount) { fp in
                    interleaved.append(contentsOf: UnsafeBufferPointer(start: fp, count: floatCount))
                }
            }
            if interleaved.count >= frameLimit { break }
        }
        if reader.status == .failed, let err = reader.error {
            throw AudioIOError.undecodable(underlying: err)
        }

        // Deinterleave into a standard float32 buffer.
        let frames = interleaved.count / max(channelCount, 1)
        guard frames > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channelCount)),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let dest = buffer.floatChannelData else {
            throw AudioIOError.allocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            for ch in 0..<channelCount {
                dest[ch][frame] = interleaved[frame * channelCount + ch]
            }
        }
        return buffer
    }
}
