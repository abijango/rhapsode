import Foundation

/// Lightweight cumulative "time saved" accumulator, backed by UserDefaults.
///
/// Tracks the lifetime total seconds saved by the SmartSpeech feature. Values are persisted
/// but are **not** SwiftData models — this avoids schema migrations. Per spec §10, this
/// accumulates in proportion to actual trimmed playback progress (honest — counts only
/// what's actually listened through). Integration with playback logic is deferred to WP7.
enum SmartSpeechStats {
    // `UserDefaults.standard` is internally thread-safe but not `Sendable`; under strict
    // concurrency we reference it inline rather than holding it in static storage.
    private enum Key {
        static let totalSavedSeconds = "cadence.totalSavedSeconds"
        static let totalPlayedSeconds = "cadence.totalPlayedSeconds"
        static let updatedAt = "cadence.statsUpdatedAt"
        static let mySavedSeconds = "rhapsode.stats.mySavedSeconds"
        static let myPlayedSeconds = "rhapsode.stats.myPlayedSeconds"
        static let myUpdatedAt = "rhapsode.stats.myUpdatedAt"
        static let migratedMine = "rhapsode.stats.migratedMine.v1"
    }

    /// Total seconds saved by the SmartSpeech feature across all books, accumulated from
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

    /// Total seconds of trimmed/output CONTENT actually listened through across all books
    /// (rate-independent — counts the per-tick trimmed-domain delta, not wall-clock). Accrues on
    /// every valid playing tick regardless of trimming. Clamped to zero (never negative).
    static var totalPlayedSeconds: TimeInterval {
        get {
            let raw = UserDefaults.standard.double(forKey: Key.totalPlayedSeconds)
            return raw < 0 ? 0 : raw
        }
        set {
            let clamped = newValue < 0 ? 0 : newValue
            UserDefaults.standard.set(clamped, forKey: Key.totalPlayedSeconds)
        }
    }

    /// When the stats last changed locally (or were applied from a remote backup). Drives the
    /// last-writer-wins backup in Dropbox. nil = never recorded.
    static var updatedAt: Date? {
        get { UserDefaults.standard.object(forKey: Key.updatedAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Key.updatedAt) }
    }

    /// Add saved seconds to the cumulative total, clamping negatives to zero.
    /// - Parameter seconds: seconds to add; negative values are treated as zero (no-op).
    static var mySavedSeconds: TimeInterval {
        get {
            migrateMineIfNeeded()
            let raw = UserDefaults.standard.double(forKey: Key.mySavedSeconds)
            return raw < 0 ? 0 : raw
        }
        set { UserDefaults.standard.set(newValue < 0 ? 0 : newValue, forKey: Key.mySavedSeconds) }
    }

    static var myPlayedSeconds: TimeInterval {
        get {
            migrateMineIfNeeded()
            let raw = UserDefaults.standard.double(forKey: Key.myPlayedSeconds)
            return raw < 0 ? 0 : raw
        }
        set { UserDefaults.standard.set(newValue < 0 ? 0 : newValue, forKey: Key.myPlayedSeconds) }
    }

    static var myUpdatedAt: Date? {
        get { UserDefaults.standard.object(forKey: Key.myUpdatedAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Key.myUpdatedAt) }
    }

    static func migrateMineIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Key.migratedMine) else { return }
        UserDefaults.standard.set(true, forKey: Key.migratedMine)
        if UserDefaults.standard.object(forKey: Key.myPlayedSeconds) == nil {
            UserDefaults.standard.set(0.0, forKey: Key.myPlayedSeconds)
        }
        if UserDefaults.standard.object(forKey: Key.mySavedSeconds) == nil {
            UserDefaults.standard.set(0.0, forKey: Key.mySavedSeconds)
        }
        if myUpdatedAt == nil { myUpdatedAt = updatedAt ?? Date() }
    }

    static func addSaved(_ seconds: TimeInterval) {
        let clamped = seconds < 0 ? 0 : seconds
        guard clamped > 0 else { return }
        migrateMineIfNeeded()
        totalSavedSeconds += clamped
        mySavedSeconds += clamped
        let now = Date()
        updatedAt = now
        myUpdatedAt = now
    }

    /// Add listened content seconds to the cumulative played total, clamping negatives to zero.
    /// - Parameter seconds: seconds to add; negative values are treated as zero (no-op).
    static func addPlayed(_ seconds: TimeInterval) {
        let clamped = seconds < 0 ? 0 : seconds
        guard clamped > 0 else { return }
        migrateMineIfNeeded()
        totalPlayedSeconds += clamped
        myPlayedSeconds += clamped
        let now = Date()
        updatedAt = now
        myUpdatedAt = now
    }

    /// Overwrite the lifetime totals locally and stamp `updatedAt = now` so the next cross-device
    /// push wins last-writer-wins. Used by "Recalculate" in Settings to rebuild the totals from the
    /// actual per-book data (e.g. to clear stale/seeded values).
    /// Rewrite this device's contribution (Recalculate). Display totals are refreshed after pull.
    static func overwrite(savedSeconds: TimeInterval, playedSeconds: TimeInterval) {
        migrateMineIfNeeded()
        mySavedSeconds = max(0, savedSeconds)
        myPlayedSeconds = max(0, playedSeconds)
        let now = Date()
        myUpdatedAt = now
        updatedAt = now
        totalSavedSeconds = mySavedSeconds
        totalPlayedSeconds = myPlayedSeconds
    }

    static func applyDisplayTotals(savedSeconds: TimeInterval, playedSeconds: TimeInterval) {
        totalSavedSeconds = max(0, savedSeconds)
        totalPlayedSeconds = max(0, playedSeconds)
        updatedAt = Date()
    }

    /// Adopt totals from a (newer) remote backup. Does NOT stamp a new `updatedAt` — it carries the
    /// remote's so the next push won't bounce. Caller decides the LWW comparison.
    static func apply(savedSeconds: TimeInterval, playedSeconds: TimeInterval, updatedAt stamp: Date) {
        totalSavedSeconds = savedSeconds
        totalPlayedSeconds = playedSeconds
        updatedAt = stamp
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
