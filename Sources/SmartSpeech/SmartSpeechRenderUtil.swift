import AVFoundation
import Foundation

/// Shared audio helpers reused by the live silence-trimming engine: window chunking (so the live
/// prescan/splice matches the reference oracle) and target-bitrate selection for AAC export.
///
/// Extracted from the former batch pre-render renderer, which was removed once live trimming became
/// the default player. Only the pure, stateless helpers the live path depends on remain here.
enum SmartSpeechRenderUtil {
    struct Window: Equatable { let start: TimeInterval; let end: TimeInterval }

    /// Expand cut points into render windows, subdividing any window longer than the cap into
    /// equal fixed-size sub-chunks. Cut points at/after `totalDuration` are dropped; a leading 0
    /// and a trailing `totalDuration` are always present.
    static func chunkWindows(cutPoints: [TimeInterval], totalDuration: TimeInterval,
                             maxChunkSeconds: TimeInterval) -> [Window] {
        var bounds = cutPoints.filter { $0 > 0 && $0 < totalDuration }.sorted()
        bounds.insert(0, at: 0)
        bounds.append(totalDuration)

        var windows: [Window] = []
        for i in 0..<(bounds.count - 1) {
            let a = bounds[i], b = bounds[i + 1]
            let len = b - a
            guard len > 0 else { continue }
            if len <= maxChunkSeconds {
                windows.append(Window(start: a, end: b))
            } else {
                let parts = Int(ceil(len / maxChunkSeconds))
                let step = len / Double(parts)
                for p in 0..<parts {
                    let s = a + Double(p) * step
                    let e = (p == parts - 1) ? b : a + Double(p + 1) * step
                    windows.append(Window(start: s, end: e))
                }
            }
        }
        return windows
    }

    /// Target AAC bitrate ≥ source (spec §6). Falls back to a spoken-word-appropriate default
    /// when the source rate can't be read.
    static func targetBitRate(for url: URL, channels: AVAudioChannelCount) -> Int {
        let fallback = channels >= 2 ? 128_000 : 96_000
        let asset = AVURLAsset(url: url)
        if let track = asset.tracks(withMediaType: .audio).first {
            let est = Int(track.estimatedDataRate)
            if est > 0 { return max(est, fallback) }
        }
        return fallback
    }
}
