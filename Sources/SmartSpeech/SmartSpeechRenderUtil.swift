import Foundation

/// Window chunking for the live silence-trimming engine so prescan and splice use the same
/// decode windows (and stay aligned with the CadenceLab oracle).
enum SmartSpeechRenderUtil {
    struct Window: Equatable { let start: TimeInterval; let end: TimeInterval }

    /// Expand cut points into decode windows, subdividing any window longer than the cap into
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
}
