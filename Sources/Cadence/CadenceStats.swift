import Foundation

/// Lightweight cumulative "time saved" accumulator, backed by UserDefaults.
///
/// Tracks the lifetime total seconds saved by the Cadence feature. Values are persisted
/// but are **not** SwiftData models — this avoids schema migrations. Per spec §10, this
/// accumulates in proportion to actual trimmed playback progress (honest — counts only
/// what's actually listened through). Integration with playback logic is deferred to WP7.
enum CadenceStats {
    // `UserDefaults.standard` is internally thread-safe but not `Sendable`; under strict
    // concurrency we reference it inline rather than holding it in static storage.
    private enum Key {
        static let totalSavedSeconds = "cadence.totalSavedSeconds"
    }

    /// Total seconds saved by the Cadence feature across all books, accumulated from
    /// trimmed playback progress. Clamped to zero (never negative).
    static var totalSavedSeconds: TimeInterval {
        get {
            let raw = UserDefaults.standard.double(forKey: Key.totalSavedSeconds)
            return raw < 0 ? 0 : raw
        }
        set {
            let clamped = newValue < 0 ? 0 : newValue
            UserDefaults.standard.set(clamped, forKey: Key.totalSavedSeconds)
        }
    }

    /// Add saved seconds to the cumulative total, clamping negatives to zero.
    /// - Parameter seconds: seconds to add; negative values are treated as zero (no-op).
    static func addSaved(_ seconds: TimeInterval) {
        let clamped = seconds < 0 ? 0 : seconds
        totalSavedSeconds += clamped
    }

    /// Formatted string representation of total saved time in the form "X h Y min saved"
    /// or "Y min saved" when less than one hour, or "0 min saved" when zero.
    /// - Returns: human-readable time-saved display string.
    static func formattedTotal() -> String {
        let total = totalSavedSeconds
        let hours = Int(total / 3600)
        let minutes = Int((total.truncatingRemainder(dividingBy: 3600)) / 60)

        if hours > 0 {
            return "\(hours) h \(minutes) min saved"
        } else {
            return "\(minutes) min saved"
        }
    }
}
