import Foundation

/// Session-relative playhead math for the live producer.
///
/// `AVAudioPlayerNode.playerTime(forNodeTime:)` is not trustworthy across
/// `AVAudioEngine` stop/start or a configuration change: it often returns the
/// previous session's large `sampleTime` (or a negative / non-finite value).
/// Treating that as "played" makes `scheduled − played` hugely negative, so the
/// producer decodes the rest of the book as fast as it can — a lock-screen CPU
/// kill (MetricKit `cpuException`) and a common path to AudioToolbox SIGTRAP.
public enum LivePlaybackClock {
    /// Slack past the last scheduled frame while the final buffer is draining.
    public static let scheduledSlack: TimeInterval = 1.0

    /// Played seconds on this session's timeline, or `lastGood` when `rawSeconds`
    /// is missing / garbage.
    public static func sessionPlayed(
        rawSeconds: TimeInterval?,
        scheduledOutput: TimeInterval,
        lastGood: TimeInterval
    ) -> TimeInterval {
        let scheduled = max(0, scheduledOutput)
        let fallback = min(max(0, lastGood), scheduled)
        guard let raw = rawSeconds, raw.isFinite, raw >= 0 else { return fallback }
        if raw > scheduled + scheduledSlack { return fallback }
        return raw
    }
}
