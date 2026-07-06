#if DEBUG
import AVFoundation
import Foundation
import SmartSpeechKit

/// EXPLORATION MODULE — M3 oracle A/B aid. Renders a source file through the *same* per-chunk splice
/// and chunk sizing the live engine uses, streamed to an `.m4a` in Documents, so the output can be
/// auditioned against the `cadence` CLI oracle (CadenceLab) for the same book + tier.
///
/// This is NOT how the live engine plays (that schedules PCM in real time) — it is a faithful offline
/// capture of the *bytes* the live path produces, using `LiveTrimProducer`'s chunk length so the
/// chunk-seam behavior matches. Since the per-chunk render is literally `TrimRenderer`, any
/// difference from the shipped renderer is seam placement only.
enum LiveSmartSpeechExport {
    /// Live-engine chunk length (keep in sync with `LiveTrimProducer.chunkSeconds`).
    static let chunkSeconds: TimeInterval = 12

    /// Render `url` to a trimmed `.m4a` and return its path. Runs off the main actor.
    static func exportTrimmed(url: URL, preset: SmartSpeechSettings.Preset) throws -> URL {
        let settings = SmartSpeechSettings(preset: preset)
        let probe = try AVAudioFile(forReading: url)
        let sampleRate = probe.processingFormat.sampleRate
        let channels = probe.processingFormat.channelCount
        let duration = Double(probe.length) / sampleRate

        let outURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("live-cadence-\(preset.rawValue)-\(url.deletingPathExtension().lastPathComponent).m4a")
        try? FileManager.default.removeItem(at: outURL)

        let writer = try AudioIO.AACFileWriter(
            url: outURL, sampleRate: sampleRate, channelCount: channels,
            bitRate: SmartSpeechRenderUtil.targetBitRate(for: url, channels: channels))

        var start: TimeInterval = 0
        while start < duration {
            let end = min(start + chunkSeconds, duration)
            try autoreleasepool {
                let decoded = try AudioIO.decode(url, startSeconds: start, durationSeconds: end - start,
                                                 maxSeconds: chunkSeconds + 5)
                let mono = AudioIO.downmixToMono(decoded)
                let profile = SilenceAnalyzer.profile(monoSamples: mono, sampleRate: sampleRate)
                let regions = SilenceAnalyzer(settings: settings).regions(from: profile)
                let rendered = try TrimRenderer(settings: settings).render(buffer: decoded, regions: regions)
                try writer.append(rendered)
            }
            start = end
        }
        writer.finish()
        return outURL
    }
}
#endif
