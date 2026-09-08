import AVFoundation
import SmartSpeechKit
import Foundation
import MediaPlayer
import SwiftData
import UIKit

/// Plays an `Audiobook`, handling both formats behind one `(trackIndex, offset)`
/// model, plus background audio, lock-screen/Control-Center controls, and resume.
///
/// Two playback shapes, detected from the tracks:
///   • single-file (M4B): all tracks share one file; track boundaries are the
///     prefix sums of chapter durations — seek within the single item.
///   • multi-file (MP3 folder): one item per track; advance on item-end.
///
/// Playback is driven by `LiveAudioBackend` (live silence-trimming AVAudioEngine),
/// not `AVPlayer`. The backend speaks SOURCE time natively: the player asks for
/// `backend.currentSource` and calls `backend.seek(toSource:)`, so all position
/// math stays source-domain. Every book plays LIVE from the original file, gated by
/// `resolvedSmartSpeech` (`.on` ⇒ trim silence on the fly; `.off` ⇒ play as-is).
@MainActor
@Observable
final class AudiobookPlayer {
    private(set) var book: Audiobook?
    private(set) var tracks: [AudiobookTrack] = []
    private(set) var currentIndex = 0
    private(set) var offsetInTrack: Double = 0
    private(set) var isPlaying = false
    /// Session-only sleep timer end; nil when off or expired.
    private(set) var sleepTimerEnd: Date?
    /// Current AVAudioSession output, e.g. "BATMAN'S AIRPODS PRO" — shown above the player dock.
    private(set) var outputRouteName = AudiobookPlayer.liveOutputRouteName()
    var rate: Float = 1.0 { didSet { backend.rate = rate; updateNowPlaying() } }

    private let backend = LiveAudioBackend()
    private var isSingleFile = false
    private var prefixSums: [Double] = []   // single-file: cumulative start time per track
    private var context: ModelContext?
    private var lastPersist = Date(timeIntervalSince1970: 0)
    /// Minimum interval between unforced position/stats persists during playback (~30s).
    private static let positionPersistInterval: TimeInterval = 30

    /// True when the live backend is trimming silence for the current file (`resolvedSmartSpeech == .on`).
    /// Replaces the old `activeMap != nil` check — gates the time-saved stat accumulation.
    private var trimActive = false
    /// The file URL currently loaded into `backend` (nil = nothing loaded). A single-file M4B loads
    /// once; chapter changes within it are seeks. A multi-file book reloads on each track change.
    private var loadedURL: URL?
    /// Per-file cache of analyze-ahead prescan results (Fix A). Seeded by a detached prescan on
    /// first load of a file; the global floor is passed into `backend.load` on any later load.
    private var prescanByURL: [URL: LiveSilencePrescanResult] = [:]
    /// In-flight prescan for the current load; cancelled when the file/book changes
    /// or when the app backgrounds (lock-screen playback cannot afford a second
    /// full-file decode alongside the live producer).
    private var prescanTask: Task<Void, Never>?
    /// Restarted when the scene becomes active if the current file still needs a scan.
    private var prescanPending: (url: URL, cuts: [TimeInterval], preset: SmartSpeechSettings.Preset)?
    private var sleepTimerTask: Task<Void, Never>?

    // AVAudioSession event handling. AVPlayer handled these implicitly; the AVAudioEngine-based
    // backend does not, so the player owns interruption + route-change reactions.
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    /// Set when playback was paused by an interruption we began, so `.ended` (with `.shouldResume`)
    /// can resume only in that case — not after a user-initiated pause.
    private var wasInterrupted = false

    /// Cached lock-screen artwork for the current cover path (avoid reloading on every tick).
    private var nowPlayingCoverPath: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    /// Fired (with `book.sourcePath`) when the persisted position genuinely changed and is
    /// user-driven (not a remote auto-jump), so the app can upload the latest position more
    /// than just on navigate-away. Throttled from `persist(force:false)` (~25s, a SEPARATE
    /// throttle from the ~30s local-persist throttle below); fires immediately on pause, seek,
    /// and track-jump (where `persist(force:true)` runs). Wired in `RhapsodeApp`.
    var onProgressChanged: ((_ sourcePath: String) -> Void)?
    /// Last time a push was attempted via `onProgressChanged`. Gates the unforced (tick) push
    /// to ~25s so background playback pushes periodically without spamming the network.
    private var lastPushAttempt = Date(timeIntervalSince1970: 0)

    // MARK: Cross-device progress sync (WP-A — last-writer-wins by change time)
    /// The (index, offset) last written to the model. Seeded in `load()` to the restored
    /// position so merely opening a book is NOT seen as a change. `persist()` compares the
    /// new position against this to decide whether to stamp `progressUpdatedAt`.
    private var lastPersistedIndex: Int?
    private var lastPersistedOffset: Double?
    /// WP-C — set true while applying a remote (cross-device) position so `persist()` updates
    /// the stored position WITHOUT stamping `progressUpdatedAt` (the position carries the
    /// REMOTE timestamp; re-stamping it as a local change would bounce it back, anti-echo).
    private var applyingRemote = false
    /// WP-C race hardening — book-time target of an in-flight remote-applied seek. The backend
    /// seek lands asynchronously; while this is non-nil, `tick()` skips so a stale PRE-seek
    /// position can't be re-derived and persisted/stamped/pushed back over the merge (which
    /// would bounce the origin device). Cleared once the position reaches the target (~1s) or
    /// `remoteSettleDeadline` passes (a safety so a never-landing seek can't freeze ticks).
    private var remoteSettleTarget: Double?
    private var remoteSettleDeadline = Date(timeIntervalSince1970: 0)
    /// Remote-command handlers are registered once for this app-lifetime player.
    private var didConfigureRemoteCommands = false

    // MARK: WP7 — time-saved stat accumulation
    /// Last backend output (trimmed-domain) time seen by `tick()`. `nil` = no baseline yet.
    private var lastPlayerTime: Double?
    /// Last source-domain time corresponding to `lastPlayerTime`. `nil` = no baseline yet.
    private var lastSourceTime: Double?

    /// Per-book listened/saved seconds accrued since the last model flush (see `flushPendingStats`).
    private var pendingListenedSeconds: Double = 0
    private var pendingSavedSeconds: Double = 0

    #if DEBUG
    /// Debug-only: the timeline map fed to the stat-accumulation self-test seam.
    private var debugStatMap: SmartSpeechTimelineMap?
    #endif

    // MARK: Init

    init() {
        backend.onTick = { [weak self] in self?.tick() }
        backend.onReachedEnd = { [weak self] in self?.handleItemEnd() }
        backend.onEngineInvalidated = { [weak self] in self?.reloadAfterEngineInvalidation() }

        let nc = NotificationCenter.default
        // AVAudioSession posts on an arbitrary thread. Extract the primitive (Sendable) payload in
        // the notification closure, then hop to the main actor with only those values + weak self.
        interruptionObserver = nc.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            let optionsRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            Task { @MainActor in self?.handleInterruption(typeRaw: typeRaw, optionsRaw: optionsRaw) }
        }
        routeChangeObserver = nc.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
            Task { @MainActor in self?.handleRouteChange(reasonRaw: reasonRaw) }
        }
    }

    /// Accumulate honest saved time from one tick to the next.
    ///
    /// The guard is on `trimmedDelta` (how far the backend output advanced) only. When playback
    /// crosses a collapsed gap, `sourceDelta` leaps by several seconds while `trimmedDelta` stays
    /// small — that IS the saving. Capping on `sourceDelta` would discard it.
    ///
    /// Skipped conditions (no accumulation):
    /// - Not playing, or `trimActive == false` (original file, no savings).
    /// - No baseline yet (first tick after load or discontinuity).
    /// - `trimmedDelta < 0`: backward seek, load/session reset, or smart-resume nudge (the backend's
    ///   `currentOutput` is session-relative and resets on seek/load, so a fresh session drops it).
    /// - `trimmedDelta >= 4.0`: forward skip/jump (above `maxRate × interval` budget).
    ///
    /// Always updates `lastPlayerTime`/`lastSourceTime` so the next tick has a fresh baseline.
    private func accumulateSaved(playerNow: Double, sourceNow: Double) {
        defer { lastPlayerTime = playerNow; lastSourceTime = sourceNow }
        guard isPlaying, let lp = lastPlayerTime, let ls = lastSourceTime else { return }
        let trimmedDelta = playerNow - lp
        let sourceDelta  = sourceNow - ls
        guard trimmedDelta >= 0, trimmedDelta < 4.0 else { return }

        // WP7 — played: trimmed/output CONTENT seconds actually listened through, accrued on EVERY
        // valid playing tick regardless of trimming (rate-independent; this is the per-tick output delta).
        SmartSpeechStats.addPlayed(trimmedDelta)                                          // lifetime/global
        pendingListenedSeconds += trimmedDelta                                            // per-book (flushed in persist)

        // WP7 — saved: only meaningful while trimming (the source outran the output across a gap).
        guard trimActive else { return }
        let saved = max(0, sourceDelta - trimmedDelta)
        guard saved > 0 else { return }
        SmartSpeechStats.addSaved(saved)                                  // lifetime/global total
        pendingSavedSeconds += saved                                      // per-book (flushed in persist)
        // All persist via the throttled persist() in tick() (or force-save on pause).
    }

    /// Write accrued per-book stats onto the model. Called from `persist()` and other force-save paths.
    private func flushPendingStats() {
        guard let book else {
            pendingListenedSeconds = 0
            pendingSavedSeconds = 0
            return
        }
        if pendingListenedSeconds > 0 {
            if let mine = book.myListenedSeconds {
                book.myListenedSeconds = mine + pendingListenedSeconds
            }
            book.listenedSeconds = (book.listenedSeconds ?? 0) + pendingListenedSeconds
            pendingListenedSeconds = 0
        }
        if pendingSavedSeconds > 0 {
            if let mine = book.mySmartSpeechSavedSeconds {
                book.mySmartSpeechSavedSeconds = mine + pendingSavedSeconds
            }
            book.smartSpeechSavedSeconds = (book.smartSpeechSavedSeconds ?? 0) + pendingSavedSeconds
            pendingSavedSeconds = 0
        }
    }

    /// Apply a completed prescan to the live backend when still relevant to the current load.
    private func applyPrescanResult(_ result: LiveSilencePrescanResult, for url: URL) {
        guard loadedURL == url else { return }
        prescanByURL[url] = result
        prescanPending = nil
        backend.applyPrescan(result)
    }

    /// Scene-phase hook from `RootTabView`. Locking the phone must not keep a
    /// whole-file decode running next to live playback — that is the MetricKit
    /// cpuException in the diagnostic log (48s CPU in 51s).
    func handleAppActive(_ active: Bool) {
        backend.setAppForegrounded(active)
        if active {
            resumePrescanIfNeeded()
        } else {
            suspendPrescanForBackground()
        }
    }

    private func startPrescan(url: URL, cuts: [TimeInterval],
                              preset: SmartSpeechSettings.Preset, bookID: UUID) {
        prescanPending = (url, cuts, preset)
        prescanTask?.cancel()
        DiagnosticLog.info("prescan start \(url.lastPathComponent)", category: .smartspeech)
        prescanTask = Task.detached(priority: .utility) { [weak self] in
            let result: LiveSilencePrescanResult?
            do {
                result = try LiveSilencePrescan.analyze(
                    url: url, cutPoints: cuts, preset: preset,
                    isCancelled: { Task.isCancelled }
                )
            } catch {
                result = nil
            }
            guard !Task.isCancelled, let result else { return }
            await MainActor.run {
                guard let self, self.loadedURL == url, self.book?.id == bookID else { return }
                DiagnosticLog.info(
                    "prescan done regions=\(result.regionCount) floor=\(String(format: "%.1f", result.globalFloorDb))",
                    category: .smartspeech
                )
                self.applyPrescanResult(result, for: url)
            }
        }
    }

    private func suspendPrescanForBackground() {
        guard prescanTask != nil else { return }
        DiagnosticLog.info("prescan pause (background)", category: .smartspeech)
        prescanTask?.cancel()
        prescanTask = nil
    }

    private func resumePrescanIfNeeded() {
        guard let pending = prescanPending, let book,
              loadedURL == pending.url, prescanByURL[pending.url] == nil,
              prescanTask == nil else { return }
        startPrescan(url: pending.url, cuts: pending.cuts, preset: pending.preset, bookID: book.id)
    }

    private func reloadAfterEngineInvalidation() {
        guard loadedURL != nil, currentTrack != nil else { return }
        let sourceNow: Double = isSingleFile ? bookTime : offsetInTrack
        let wasPlaying = isPlaying
        loadedURL = nil
        if isSingleFile {
            loadCurrentItem(seekTo: max(0, sourceNow - (prefixSums.indices.contains(currentIndex) ? prefixSums[currentIndex] : 0)))
        } else {
            loadCurrentItem(seekTo: sourceNow)
        }
        if wasPlaying { play() }
    }

    /// WP8 — smart resume flag. Set `true` on `pause()` and on initial `load()`, cleared by any
    /// deliberate seek (`seekWithinBook`, `seekInTrack`, `jump`) so a scrub-then-play is never
    /// yanked back. Consumed and cleared by `play()`.
    private var pendingResumeNudge = false

    // MARK: WP8 — Smart resume

    /// Nudge the source-domain playback position back to just before a pause (spec §11).
    ///
    /// The live backend does not expose a silence-onset map here, so this is the fixed ~1.5 s
    /// backstep fallback: step back 1.5 s of SOURCE time, only ever backward, and never past 0.
    /// Called only from `play()` when `pendingResumeNudge` is set.
    private func applySmartResumeNudge() {
        // single-file: bookTime is book-level source time; multi-file: offsetInTrack is file-local source.
        let currentSource: Double = isSingleFile ? bookTime : offsetInTrack
        guard currentSource.isFinite && currentSource > 0 else { return }
        let target = max(currentSource - 1.5, 0)
        guard target < currentSource else { return }
        if isSingleFile {
            seekSingleFile(to: target)
        } else {
            let clamped = min(max(target, 0), trackDuration)
            backend.seek(toSource: clamped)
            offsetInTrack = clamped
            lastPlayerTime = nil
            lastSourceTime = nil
        }
    }

    var currentTrack: AudiobookTrack? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }
    var trackDuration: Double { currentTrack?.duration ?? 0 }
    /// Whether live silence-trimming is active for the currently-loaded file (SmartSpeech on for this
    /// book). Exposed for the per-book live stats panel.
    var isTrimming: Bool { trimActive }

    // MARK: Lifecycle

    func load(_ book: Audiobook, context: ModelContext) {
        self.context = context
        // Idempotent: re-entering the player for the already-loaded book must NOT
        // restart playback. The player is app-lifetime (injected via environment),
        // so it keeps playing as the user navigates away (tab switch / back to the
        // shelf) and returns — re-running load() here would reset the position.
        if self.book?.id == book.id { return }
        // Switching to a different book: persist & stop the previous one first.
        if self.book != nil { teardown() }

        self.book = book
        self.tracks = book.orderedTracks
        self.isSingleFile = Self.detectSingleFile(tracks)
        self.prefixSums = Self.computePrefixSums(tracks)
        self.currentIndex = min(max(book.lastTrackIndex, 0), max(tracks.count - 1, 0))
        self.offsetInTrack = book.lastOffsetSeconds
        // WP-A: seed the change baseline to the restored position so the first persist after
        // load() does NOT mistake "opened the book" for a user move and phantom-stamp.
        self.lastPersistedIndex = self.currentIndex
        self.lastPersistedOffset = self.offsetInTrack

        // WP7: clear the stat baseline on every new load so stale state from a previous book
        // does not pollute the first tick.
        lastPlayerTime = nil
        lastSourceTime = nil
        pendingListenedSeconds = 0
        pendingSavedSeconds = 0
        prescanTask?.cancel()
        prescanTask = nil

        DiagnosticLog.info("load “\(book.title)” track=\(currentIndex) offset=\(String(format: "%.1f", offsetInTrack))", category: .playback)
        configureAudioSession()   // before any backend use (engine needs an active session)
        configureRemoteCommands()
        loadCurrentItem(seekTo: offsetInTrack)
        pendingResumeNudge = true   // WP8: initial load arms the smart-resume nudge
    }

    /// Force-persist the current position now, WITHOUT stopping playback. Called
    /// when the player view goes away but audio should keep playing (tab switch /
    /// back to the shelf), so the pushed cross-device position is current.
    func savePosition() { persist(force: true) }

    /// Persist position and stop. Called when switching to a different book (from `load`),
    /// not on every view disappearance.
    func teardown() {
        if let title = book?.title {
            DiagnosticLog.info("teardown “\(title)”", category: .playback)
        }
        persist(force: true)
        cancelSleepTimer()
        prescanTask?.cancel()
        prescanTask = nil
        prescanPending = nil
        isPlaying = false
        backend.stop()
        loadedURL = nil
        nowPlayingCoverPath = nil
        nowPlayingArtwork = nil
        updateNowPlaying()
    }

    // MARK: Transport

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        // WP8 — smart resume: nudge position back before playing, but only when the flag was armed
        // (initial load or pause). Deliberate seeks clear the flag so scrub-then-play isn't yanked back.
        if pendingResumeNudge {
            pendingResumeNudge = false
            applySmartResumeNudge()
        }
        backend.rate = rate
        backend.play()
        isPlaying = true
        DiagnosticLog.info("play “\(book?.title ?? "?")”", category: .playback)
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        backend.pause()
        pendingResumeNudge = true   // WP8: arm so next play() nudges
        persist(force: true)
        updateNowPlaying()
    }

    /// Session-only sleep timer. Pauses playback when it fires; does not persist across launches.
    func setSleepTimer(minutes: Int?) {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEnd = nil
        guard let minutes, minutes > 0 else { return }
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEnd = end
        sleepTimerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TimeInterval(minutes * 60)))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.sleepTimerEnd == end else { return }
                self.sleepTimerEnd = nil
                self.sleepTimerTask = nil
                if self.isPlaying { self.pause() }
            }
        }
    }

    func cancelSleepTimer() { setSleepTimer(minutes: nil) }

    /// Remaining sleep-timer label for menus, e.g. `"12m"`, or nil when off.
    var sleepTimerRemainingLabel: String? {
        guard let end = sleepTimerEnd else { return nil }
        let remaining = end.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        let minutes = Int(ceil(remaining / 60))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Skip relative seconds within the book (crosses track boundaries).
    func skip(_ seconds: Double) {
        seekWithinBook(toBookTime: bookTime + seconds)
    }

    /// WP-C — reconcile the live player to a newer position merged from another device.
    /// Acts ONLY if this player currently holds `bookID`. Seeks to the source-domain
    /// position `prefixSums[trackIndex] + offsetSeconds` WITHOUT stamping a new
    /// change-time or pushing (anti-echo, rule 3): the merged model already carries the
    /// remote timestamp. This also reconciles the player's cached in-memory position so a
    /// later `persist()` can't write the stale local value back over the merge.
    func applyRemotePosition(bookID: UUID, trackIndex: Int, offsetSeconds: Double) {
        guard book?.id == bookID, tracks.indices.contains(trackIndex) else { return }
        let base = prefixSums.indices.contains(trackIndex) ? prefixSums[trackIndex] : 0
        let target = base + max(0, offsetSeconds)
        applyingRemote = true
        // seekWithinBook persists (force) — under applyingRemote it updates the position +
        // baseline but does NOT stamp progressUpdatedAt or fire the push.
        seekWithinBook(toBookTime: target)
        applyingRemote = false
        // The backend seek lands asynchronously; arm the settle guard so ticks ignore the
        // stale pre-seek position until it reaches `target` (or the deadline elapses).
        remoteSettleTarget = target
        remoteSettleDeadline = Date().addingTimeInterval(2.0)
    }

    /// Seek within the current track (0...trackDuration).
    func seekInTrack(to seconds: Double) {
        pendingResumeNudge = false   // WP8: deliberate seek — do not nudge on next play()
        let clamped = min(max(seconds, 0), trackDuration)
        if isSingleFile {
            seekSingleFile(to: prefixSums[currentIndex] + clamped)
        } else {
            backend.seek(toSource: clamped)
            offsetInTrack = clamped
            lastPlayerTime = nil
            lastSourceTime = nil
        }
        updateNowPlaying()
        persist(force: true)   // WP-B: a deliberate seek is a user move — persist + push it now.
    }

    /// Book-domain scrub target (source time across the whole book). Powers the single thick progress
    /// bar in the player, which is book-domain so it works identically for M4B and multi-file books.
    func seekInBook(to bookTime: Double) { seekWithinBook(toBookTime: bookTime) }

    func jump(toTrack index: Int) {
        pendingResumeNudge = false   // WP8: track jump is deliberate — do not nudge
        guard tracks.indices.contains(index) else { return }
        currentIndex = index
        offsetInTrack = 0
        if isSingleFile {
            seekSingleFile(to: prefixSums[index])
        } else {
            loadCurrentItem(seekTo: 0)
        }
        if isPlaying { backend.play() }
        updateNowPlaying()
        persist(force: true)
    }

    // MARK: Item loading

    private func loadCurrentItem(seekTo offset: Double) {
        guard let track = currentTrack, let book,
              let url = try? ContainerPaths.url(forRelativePath: track.fileRelPath) else { return }

        // Trim gate + tier from the single resolver: `.off` ⇒ play original as-is; `.on(preset)` ⇒
        // live-trim the original at that tier. Every book plays LIVE from the original file now.
        let trimEnabled: Bool
        let preset: SmartSpeechSettings.Preset
        switch book.resolvedSmartSpeech {
        case .off:            trimEnabled = false; preset = .default
        case .on(let p):      trimEnabled = true;  preset = p
        }
        trimActive = trimEnabled

        // Source-domain session parameters. For a single-file M4B the backend loads the whole file
        // once and seeks between chapters; for multi-file each track is its own file (offset 0-based).
        let startSource = isSingleFile ? prefixSums[currentIndex] + offset : offset
        let srcDuration = isSingleFile ? totalDuration : trackDuration
        let cuts = isSingleFile ? prefixSums : [0]

        if loadedURL != url {
            loadedURL = url
            let cached = prescanByURL[url]
            backend.load(url: url, sourceDuration: srcDuration, cutPoints: cuts,
                         startSource: startSource, trimEnabled: trimEnabled,
                         preset: preset, globalFloorDb: cached?.globalFloorDb)
            // Re-apply full cached regions (not just floor) so playback skips live RMS.
            if let cached { backend.applyPrescan(cached) }
            // Analyze-ahead once per file when no cache yet (regions + global floor/speech).
            if trimEnabled, cached == nil {
                startPrescan(url: url, cuts: cuts, preset: preset, bookID: book.id)
            } else {
                prescanPending = nil
            }
        } else {
            // Same file already loaded (e.g. single-file chapter change) — just reposition.
            backend.seek(toSource: startSource)
        }
        // Fresh session: reset the stat baseline so a cross-session output delta isn't counted.
        lastPlayerTime = nil
        lastSourceTime = nil
    }


    /// Re-evaluate the trim setting for the current book and reload the backend at the preserved
    /// source position so the change (SmartSpeech toggled on/off, or tier changed) takes effect without
    /// losing the listener's place. Called from: (a) SmartSpeech toggle mid-play; (b) WP9 tier change.
    func applySmartSpeechChange() {
        guard let book, currentTrack != nil else { return }

        // Capture the current source position BEFORE reloading.
        let sourceNow: Double = isSingleFile ? bookTime : offsetInTrack
        let wasPlaying = isPlaying

        let trimEnabled: Bool
        switch book.resolvedSmartSpeech {
        case .off: trimEnabled = false
        case .on:  trimEnabled = true
        }
        trimActive = trimEnabled

        // Force a reload with the new trim setting at the preserved position.
        prescanTask?.cancel()
        prescanTask = nil
        prescanPending = nil
        loadedURL = nil
        if isSingleFile {
            loadCurrentItem(seekTo: max(0, sourceNow - prefixSums[currentIndex]))
        } else {
            loadCurrentItem(seekTo: sourceNow)
        }
        if wasPlaying { backend.play() }
        updateNowPlaying()
    }

    private func seekSingleFile(to bookTime: Double) {
        backend.seek(toSource: bookTime)
        recomputeIndex(forBookTime: bookTime)
        lastPlayerTime = nil
        lastSourceTime = nil
    }

    private func seekWithinBook(toBookTime t: Double) {
        pendingResumeNudge = false   // WP8: deliberate seek — do not nudge on next play()
        let clamped = min(max(t, 0), totalDuration)
        if isSingleFile {
            seekSingleFile(to: clamped)
        } else {
            // Find target track + offset from prefix sums.
            let idx = trackIndex(forBookTime: clamped)
            let off = clamped - prefixSums[idx]
            if idx != currentIndex {
                currentIndex = idx
                loadCurrentItem(seekTo: off)
            } else {
                backend.seek(toSource: off)
                lastPlayerTime = nil
                lastSourceTime = nil
            }
            offsetInTrack = off
        }
        if isPlaying { backend.play() }
        updateNowPlaying()
        persist(force: true)   // WP-B: a deliberate seek is a user move — persist + push it now.
    }

    // MARK: AVAudioSession events

    private func handleInterruption(typeRaw: UInt, optionsRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            if isPlaying { wasInterrupted = true; pause() }
        case .ended:
            if wasInterrupted {
                wasInterrupted = false
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                if options.contains(.shouldResume) { play() }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRaw: UInt) {
        refreshOutputRoute()
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        // Headphones/route unplugged mid-play: pause rather than blast audio out the speaker.
        if reason == .oldDeviceUnavailable, isPlaying { pause() }
    }

    func refreshOutputRoute() {
        outputRouteName = Self.liveOutputRouteName()
    }

    static func liveOutputRouteName() -> String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.isEmpty { return "SPEAKER" }
        return outputs.map(\.portName).joined(separator: " + ").uppercased()
    }

    // MARK: Tick (driven by the backend's display loop)

    private func tick() {
        let sourceNow = backend.currentSource
        guard sourceNow.isFinite else { return }
        // WP-C race hardening: while a remote-applied seek is still settling, the backend may still
        // report its PRE-seek position. Skip the tick until it reaches the target so a stale position
        // isn't persisted/stamped/pushed (which would clobber the merge). Clear on landing (~1s) or
        // after the deadline so a never-landing seek can't freeze ticks.
        if let target = remoteSettleTarget {
            let playerBookTime = isSingleFile
                ? sourceNow
                : (prefixSums.indices.contains(currentIndex) ? prefixSums[currentIndex] : 0) + sourceNow
            if abs(playerBookTime - target) <= 1.0 || Date() >= remoteSettleDeadline {
                remoteSettleTarget = nil
            } else {
                return
            }
        }
        if isSingleFile {
            recomputeIndex(forBookTime: sourceNow)
        } else {
            offsetInTrack = sourceNow
        }
        // WP7: accumulate honest time-saved stat from trimmed playback progress.
        accumulateSaved(playerNow: backend.currentOutput, sourceNow: sourceNow)
        updateNowPlayingElapsed()
        persist(force: false)
    }

    private func handleItemEnd() {
        // Multi-file: advance to the next track. Single-file end = book end → pause.
        if !isSingleFile && currentIndex + 1 < tracks.count {
            jump(toTrack: currentIndex + 1)
        } else {
            pause()
        }
    }

    // MARK: Index math

    private func recomputeIndex(forBookTime t: Double) {
        let idx = trackIndex(forBookTime: t)
        currentIndex = idx
        offsetInTrack = max(0, t - prefixSums[idx])
    }

    private func trackIndex(forBookTime t: Double) -> Int {
        var idx = 0
        for i in tracks.indices where prefixSums[i] <= t + 0.001 { idx = i }
        return idx
    }

    private var bookTime: Double {
        // Must read stored player fields — not `backend.currentSource`. Observation only
        // invalidates views that touched a stored property; the backend is an untracked
        // let, so a live getter there freezes the on-screen clock for single-file M4Bs.
        // `tick()` / seek already keep `offsetInTrack` in source-domain sync.
        guard prefixSums.indices.contains(currentIndex) else { return offsetInTrack }
        return prefixSums[currentIndex] + offsetInTrack
    }

    var totalDuration: Double { book?.totalDuration ?? prefixSums.last.map { $0 + (tracks.last?.duration ?? 0) } ?? 0 }

    // MARK: Book-level progress (source-domain; identical math for M4B & MP3)

    /// Absolute position within the whole book, in source-domain seconds.
    /// Derived from `currentIndex` + `offsetInTrack` (already source-domain), so this
    /// is honest whether or not SmartSpeech trimming is active, and so SwiftUI
    /// observes each tick.
    var bookPosition: Double { bookTime }

    /// Fraction of the whole book completed, clamped 0...1 and NaN-safe (0 when
    /// the total duration isn't known yet).
    var bookProgress: Double {
        let total = totalDuration
        guard total > 0, bookPosition.isFinite else { return 0 }
        return min(1, max(0, bookPosition / total))
    }

    /// Source-domain seconds remaining in the book.
    var bookTimeRemaining: Double { max(0, totalDuration - bookPosition) }

    /// Number of playable segments — chapters for a single-file M4B, files for a
    /// multi-file MP3 audiobook.
    var segmentCount: Int { tracks.count }

    /// 1-based index of the current segment, clamped to a valid range.
    var currentSegmentNumber: Int { min(currentIndex + 1, max(segmentCount, 1)) }

    /// Format-aware noun for a segment: "Chapter" for chaptered single-file books,
    /// "Track" for multi-file MP3 audiobooks. The only place the two formats differ
    /// in the progress UI — the bar math is shared.
    var segmentNoun: String { isSingleFile ? "Chapter" : "Track" }

    // MARK: Persistence

    private func persist(force: Bool) {
        guard let book, let context else { return }
        let changed = currentIndex != lastPersistedIndex || offsetInTrack != lastPersistedOffset
        let statsPending = pendingListenedSeconds > 0 || pendingSavedSeconds > 0
        if !force {
            guard Date().timeIntervalSince(lastPersist) >= Self.positionPersistInterval else { return }
            // Do not hit SwiftData every tick just to refresh on-screen time — only when the
            // position moved or accrued stats need flushing.
            guard changed || statsPending else { return }
        }
        lastPersist = Date()
        flushPendingStats()
        // WP-A: stamp progressUpdatedAt ONLY when the position genuinely changed AND the change
        // is user-driven (not a remote auto-jump). The timestamp marks WHEN the user last moved,
        // so an idle device that pushes later can't clobber a newer remote with a stale position.
        if changed && !applyingRemote {
            book.progressUpdatedAt = Date()
        }
        if changed {
            book.lastTrackIndex = currentIndex
            book.lastOffsetSeconds = offsetInTrack
            book.refreshCachedFractionComplete()
            lastPersistedIndex = currentIndex
            lastPersistedOffset = offsetInTrack
        }
        try? context.save()
        // WP-B: push the latest position cross-device. Fire AFTER the save so the push (which
        // re-fetches the row by key and reads its persisted position) sends the current value.
        // Gated on `changed && !applyingRemote`: a remote-applied jump (rule 3, anti-echo) and a
        // no-op persist (e.g. teardown's pause after teardown already saved) never push. `force`
        // (pause/seek/jump) bypasses the throttle; an unforced tick pushes at most every ~25s.
        if changed && !applyingRemote && (force || Date().timeIntervalSince(lastPushAttempt) >= 25) {
            lastPushAttempt = Date()
            onProgressChanged?(book.sourcePath)
        }
    }

    // MARK: Audio session + remote

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        refreshOutputRoute()
    }

    private func configureRemoteCommands() {
        // MPRemoteCommandCenter is an app-wide singleton and addTarget stacks
        // handlers — configure exactly once for the app-lifetime player, or each
        // book switch would add another (leaking) set of command handlers.
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true
        let c = MPRemoteCommandCenter.shared()
        // MediaPlayer invokes these handlers on a non-main thread, so hop to the
        // main actor (the player is @MainActor) rather than calling directly —
        // calling main-actor methods off-main trips a dispatch-queue assertion.
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.skipForwardCommand.preferredIntervals = [30]
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(30) }; return .success }
        c.skipBackwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = e.positionTime
            Task { @MainActor in self?.seekWithinBook(toBookTime: position) }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = currentTrack?.title ?? book?.title ?? ""
        info[MPMediaItemPropertyAlbumTitle] = book?.title ?? ""
        info[MPMediaItemPropertyArtist] = book?.author ?? ""
        info[MPMediaItemPropertyPlaybackDuration] = totalDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bookPosition
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        if let coverRel = book?.coverPath {
            if coverRel == nowPlayingCoverPath, let nowPlayingArtwork {
                info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
            } else {
                Task { await loadNowPlayingArtwork(coverRel: coverRel) }
            }
        } else {
            nowPlayingCoverPath = nil
            nowPlayingArtwork = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadNowPlayingArtwork(coverRel: String) async {
        guard book?.coverPath == coverRel else { return }
        guard let loaded = await CoverImageLoader.Cache.shared.load(
            relativePath: coverRel,
            maxPixelSize: 600
        ) else { return }
        guard book?.coverPath == coverRel else { return }
        nowPlayingCoverPath = coverRel
        nowPlayingArtwork = Self.makeArtwork(loaded.image)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Build the lock-screen artwork. `nonisolated` so its request handler is NOT
    /// main-actor-isolated — MediaPlayer invokes it on its own background queue,
    /// and a main-actor-isolated closure would trip an executor assertion there.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlayingElapsed() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = bookPosition
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
    }

    // MARK: Static helpers

    private static func detectSingleFile(_ tracks: [AudiobookTrack]) -> Bool {
        guard let first = tracks.first?.fileRelPath else { return false }
        return tracks.count > 1 && tracks.allSatisfy { $0.fileRelPath == first }
    }

    private static func computePrefixSums(_ tracks: [AudiobookTrack]) -> [Double] {
        var sums: [Double] = []
        var running = 0.0
        for t in tracks { sums.append(running); running += t.duration }
        return sums
    }
}

#if DEBUG
/// Test seam for the headless self-tests. Repointed from the old AVPlayer internals to the live
/// backend so `SmartSpeechSelfTest` still builds. Not compiled in release.
extension AudiobookPlayer {
    /// A backend session is loaded (backend loads synchronously, so this is true right after `load`).
    var debugItemReady: Bool { loadedURL != nil }
    /// Live trimming is active for the current book (`resolvedSmartSpeech == .on`).
    var debugIsTrimmed: Bool { trimActive }
    /// Backend output (trimmed-domain, session-relative) seconds.
    var debugPlayerTimeSeconds: Double { backend.currentOutput }
    /// Source-domain position via the read path — for asserting a seek round-trips to S.
    var debugBookTime: Double { bookTime }
    func debugSeek(toSourceTime t: Double) { seekWithinBook(toBookTime: t) }
    func debugApplySmartSpeechChange() { applySmartSpeechChange() }
    /// WP8 test seam: arm the resume nudge flag and immediately trigger the nudge (without setting
    /// `isPlaying`). Drives the pure nudge logic deterministically without launching real playback.
    func debugSmartResumeNudge() {
        pendingResumeNudge = true
        pendingResumeNudge = false
        applySmartResumeNudge()
    }

    // MARK: WP7 debug seam — stat accumulation

    /// Prepare the player for a simulated trimmed-playback stat session. Stores `map` as the debug
    /// stat map and marks `trimActive`/`isPlaying = true` so `accumulateSaved` will count. No audio,
    /// no network — just the stat accumulation logic driven by `debugFeedPlayerTick`.
    func debugBeginSmartSpeechStatSession(map: SmartSpeechTimelineMap, book: Audiobook? = nil) {
        self.book = book
        debugStatMap = map
        trimActive = true
        isPlaying = true
        lastPlayerTime = nil
        lastSourceTime = nil
    }

    /// Per-book accrued savings for the session's book (S2), for the self-test to assert.
    var debugBookSavedSeconds: Double? {
        guard let book else { return nil }
        return (book.smartSpeechSavedSeconds ?? 0) + pendingSavedSeconds
    }

    /// Feed a single simulated tick at `playerTime` (trimmed-domain seconds), exactly as `tick()`
    /// does. The source time is derived via the debug stat map's `toSource(playerTime)`.
    func debugFeedPlayerTick(_ playerTime: Double) {
        accumulateSaved(playerNow: playerTime, sourceNow: debugStatMap?.toSource(playerTime) ?? playerTime)
    }

    /// Tear down the stat session started by `debugBeginSmartSpeechStatSession`.
    func debugEndSmartSpeechStatSession() {
        flushPendingStats()
        isPlaying = false
        trimActive = false
        lastPlayerTime = nil
        lastSourceTime = nil
    }

    /// Inject a multi-file mock (book + tracks + position) WITHOUT loading audio, so the redesigned
    /// player chrome can be screenshotted. `bookTime` reads `prefixSums`/`offsetInTrack`.
    func debugMockPresent(book: Audiobook, tracks: [AudiobookTrack], currentIndex: Int,
                          offsetInTrack: Double, isPlaying: Bool) {
        self.book = book
        self.tracks = tracks
        self.currentIndex = currentIndex
        self.offsetInTrack = offsetInTrack
        self.isPlaying = isPlaying
        self.isSingleFile = false
        self.prefixSums = Self.computePrefixSums(tracks)
        self.trimActive = true
    }
}
#endif
