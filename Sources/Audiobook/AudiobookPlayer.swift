import AVFoundation
import CadenceKit
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
@MainActor
@Observable
final class AudiobookPlayer {
    private(set) var book: Audiobook?
    private(set) var tracks: [AudiobookTrack] = []
    private(set) var currentIndex = 0
    private(set) var offsetInTrack: Double = 0
    private(set) var isPlaying = false
    var rate: Float = 1.0 { didSet { if isPlaying { player.rate = rate }; updateNowPlaying() } }

    private let player = AVPlayer()
    private var isSingleFile = false
    private var prefixSums: [Double] = []   // single-file: cumulative start time per track
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var context: ModelContext?
    private var lastPersist = Date(timeIntervalSince1970: 0)

    // MARK: Cadence (WP5 / WP6 / WP8)
    /// Source↔trimmed map for the file currently loaded into `player`. `nil` ⇒ the loaded file
    /// IS the original (identity mapping). Set in `loadCurrentItem`: per-file for multi-file
    /// books, once for the single shared M4B file. All position math stays source-domain; we map
    /// only at the `player` boundary via `srcToPlayer` / `playerToSrc`.
    private var activeMap: CadenceTimelineMap?

    /// WP8 — smart resume flag. Set `true` on `pause()` and on initial `load()`, cleared by any
    /// deliberate seek (`seekWithinBook`, `seekInTrack`, `jump`) so a scrub-then-play is never
    /// yanked back. Consumed and cleared by `play()`.
    private var pendingResumeNudge = false

    /// The `trimmedRelPath` of the rendition currently loaded (if any). Used to update the
    /// `CadenceInUseRegistry` on load and clear on teardown / track-change.
    private var inUseTrimmedRelPath: String?

    /// Source-domain time → the time to hand `player.seek` (trimmed time when a trim is loaded).
    private func srcToPlayer(_ source: Double) -> Double { activeMap?.toTrimmed(source) ?? source }
    /// A time read from `player` → source-domain time.
    private func playerToSrc(_ playerTime: Double) -> Double { activeMap?.toSource(playerTime) ?? playerTime }

    // MARK: WP8 — Smart resume

    /// Nudge the source-domain playback position back to just before a pause (spec §11).
    ///
    /// Strategy:
    /// - When a trimmed rendition is loaded (`activeMap != nil`): ask the map for the nearest
    ///   silence onset within ~3 s. That is the source time where kept audio resumes after a
    ///   collapsed gap — exactly the start of the next word/phrase. If found, seek there.
    /// - Fallback (no map, or no onset within lookback): step back a fixed ~1.5 s.
    /// - Only ever nudges BACKWARD. A position at 0 is left as-is.
    ///
    /// The map's source axis is **file-local** for both M4B and MP3:
    /// - single-file (M4B): book source time (= prefix[index] + offsetInTrack) IS file-local.
    /// - multi-file (MP3): `offsetInTrack` is already file-local per-track.
    ///
    /// Called only from `play()` when `pendingResumeNudge` is set.
    private func applySmartResumeNudge() {
        // Capture the current source position. For single-file, bookTime = playerToSrc(player time).
        // For multi-file, offsetInTrack is already file-local source time.
        let currentSource: Double = isSingleFile ? bookTime : offsetInTrack
        guard currentSource.isFinite && currentSource > 0 else { return }

        let lookback = 3.0
        let fixedBackstep = 1.5

        if let map = activeMap,
           let onset = map.nearestSilenceOnset(beforeSource: currentSource, within: lookback) {
            // Onset is guaranteed <= currentSource by the helper; clamp to >= 0 for safety.
            let target = max(onset, 0)
            if target < currentSource { performSmartSeek(toSource: target) }
        } else {
            // Fallback: fixed backstep, only if it would move backward.
            let target = max(currentSource - fixedBackstep, 0)
            if target < currentSource { performSmartSeek(toSource: target) }
        }
    }

    /// Issue the seek for smart resume. Delegates to the same internal seek helpers so the
    /// source↔trimmed mapping is applied exactly once, at the AVPlayer boundary.
    private func performSmartSeek(toSource target: Double) {
        if isSingleFile {
            // single-file: `target` IS book-level source time (prefix sums already included).
            seekSingleFile(to: target)
        } else {
            // multi-file: `target` is file-local (= track-level) source time.
            let clamped = min(max(target, 0), trackDuration)
            player.seek(to: cmTime(srcToPlayer(clamped)))
            offsetInTrack = clamped
        }
    }

    var currentTrack: AudiobookTrack? { tracks.indices.contains(currentIndex) ? tracks[currentIndex] : nil }
    var trackDuration: Double { currentTrack?.duration ?? 0 }

    // MARK: Lifecycle

    func load(_ book: Audiobook, context: ModelContext) {
        self.book = book
        self.context = context
        self.tracks = book.orderedTracks
        self.isSingleFile = Self.detectSingleFile(tracks)
        self.prefixSums = Self.computePrefixSums(tracks)
        self.currentIndex = min(max(book.lastTrackIndex, 0), max(tracks.count - 1, 0))
        self.offsetInTrack = book.lastOffsetSeconds

        configureAudioSession()
        configureRemoteCommands()
        loadCurrentItem(seekTo: offsetInTrack)
        addPeriodicObserver()
        pendingResumeNudge = true   // WP8: initial load arms the smart-resume nudge
    }

    /// Persist position and stop. Call when leaving the player.
    func teardown() {
        persist(force: true)
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        // WP6: unmark the in-use rendition so the LRU eviction may reclaim it.
        if let rel = inUseTrimmedRelPath {
            CadenceInUseRegistry.shared.clearInUse(rel)
            inUseTrimmedRelPath = nil
        }
    }

    // MARK: Transport

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        // WP8 — smart resume: nudge position back to the nearest silence onset before playing,
        // but only when the flag was armed (initial load or pause). Deliberate seeks clear the
        // flag so scrub-then-play is never yanked back.
        if pendingResumeNudge {
            pendingResumeNudge = false
            applySmartResumeNudge()
        }
        isPlaying = true
        player.rate = rate
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        player.pause()
        pendingResumeNudge = true   // WP8: arm so next play() nudges
        persist(force: true)
        updateNowPlaying()
    }

    /// Skip relative seconds within the book (crosses track boundaries).
    func skip(_ seconds: Double) {
        seekWithinBook(toBookTime: bookTime + seconds)
    }

    /// Seek within the current track (0...trackDuration).
    func seekInTrack(to seconds: Double) {
        pendingResumeNudge = false   // WP8: deliberate seek — do not nudge on next play()
        let clamped = min(max(seconds, 0), trackDuration)
        if isSingleFile {
            seekSingleFile(to: prefixSums[currentIndex] + clamped)
        } else {
            player.seek(to: cmTime(srcToPlayer(clamped)))
            offsetInTrack = clamped
        }
        updateNowPlaying()
    }

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
        if isPlaying { player.rate = rate }
        updateNowPlaying()
        persist(force: true)
    }

    // MARK: Item loading

    private func loadCurrentItem(seekTo offset: Double) {
        guard let track = currentTrack else { return }
        // WP6: clear the previous in-use registration before selecting the new file.
        if let old = inUseTrimmedRelPath {
            CadenceInUseRegistry.shared.clearInUse(old)
            inUseTrimmedRelPath = nil
        }
        // Cadence source selection: trimmed rendition when one is valid, else the original.
        // Set `activeMap` BEFORE any srcToPlayer/seek below (the multi-file branch seeks at once).
        let url: URL
        if let trimmed = trimmedSource(for: track.fileRelPath) {
            url = trimmed.url
            activeMap = trimmed.map
            // WP6: mark this rendition as in-use so the eviction routine won't remove it.
            CadenceInUseRegistry.shared.markInUse(trimmed.relPath)
            inUseTrimmedRelPath = trimmed.relPath
        } else if let original = try? ContainerPaths.url(forRelativePath: track.fileRelPath) {
            url = original
            activeMap = nil
        } else {
            return
        }
        if isSingleFile {
            // Load the shared file once; seek to absolute book position.
            if player.currentItem == nil {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
            }
            seekSingleFile(to: prefixSums[currentIndex] + offset)
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.seek(to: cmTime(srcToPlayer(offset)))
            observeItemEnd()
        }
    }

    /// The trimmed rendition to play for `relPath`, if the feature is on and a valid rendition's
    /// audio is present on disk; else `nil` (play the original). Touches `lastUsedAt` for LRU.
    /// WP6: also returns `relPath` so `loadCurrentItem` can register it in the in-use registry.
    private func trimmedSource(for relPath: String) -> (url: URL, map: CadenceTimelineMap, relPath: String)? {
        guard let book, let context else { return nil }
        return Self.selectTrimmedSource(bookID: book.id, relPath: relPath,
                                        tier: book.effectiveCadenceTier.rawValue, context: context)
    }

    /// Pure selection contract (testable without an `AVPlayer`): feature on + a rendition matching
    /// the validity key (fingerprint + versions + tier, not evicted) whose `.m4a` exists on disk +
    /// a decodable timeline map. Any miss ⇒ `nil`.
    ///
    /// WP6 — eviction / regenerate-on-demand: if a rendition row exists for this (book, file) but
    /// its audio is evicted (`audioEvicted == true`) or the `.m4a` is missing from disk, return
    /// `nil` AND enqueue a re-render so the file is rebuilt. Other misses (no row, tier/fingerprint
    /// mismatch) do NOT re-enqueue — those cases are handled by the coordinator on its own trigger.
    /// The returned tuple now carries `relPath` so callers can update the in-use registry.
    /// WP10: returns `nil` immediately for books flagged `cadenceUnavailable` (DRM/undecodable).
    static func selectTrimmedSource(bookID: UUID, relPath: String, tier: String,
                                    context: ModelContext) -> (url: URL, map: CadenceTimelineMap, relPath: String)? {
        // WP10: DRM/undecodable books are never trimmed.
        if let book = (try? context.fetch(FetchDescriptor<Audiobook>()))?.first(where: { $0.id == bookID }),
           book.cadenceUnavailable == true { return nil }

        guard CadencePreferences.isEnabled,
              let srcURL = try? ContainerPaths.url(forRelativePath: relPath),
              let fingerprint = CadenceFingerprint.of(fileAt: srcURL)
        else { return nil }

        guard let rendition = (try? context.fetch(FetchDescriptor<TrimmedRendition>()))?
                .first(where: { $0.bookID == bookID && $0.sourceFileRelPath == relPath })
        else { return nil }   // no row — not an eviction, don't re-enqueue

        // Detect evicted or missing audio and trigger background re-render.
        let fileURL = try? ContainerPaths.cacheURL(forRelativePath: rendition.trimmedRelPath)
        let fileMissing = fileURL == nil || !FileManager.default.fileExists(atPath: fileURL!.path)
        if rendition.audioEvicted || fileMissing {
            Task { await CadenceRenderCoordinator.shared.enqueue(bookID: bookID) }
            return nil
        }

        guard rendition.isValid(forFingerprint: fingerprint, tier: tier),
              let url = fileURL,
              let map = try? JSONDecoder().decode(CadenceTimelineMap.self, from: rendition.timelineMapBlob)
        else { return nil }

        rendition.lastUsedAt = Date()
        return (url, map, rendition.trimmedRelPath)
    }

    /// WP10 — mid-session swap. Re-evaluates whether the current track should play the trimmed or
    /// original source. If the selection changed (e.g. Cadence was toggled off, or a new rendition
    /// became available), swaps the `AVPlayerItem` **at the current mapped source position** so
    /// there is no audible jump:
    ///
    /// 1. Capture `sourceNow` from the **old** map (before any changes).
    /// 2. Compute the new selection. If unchanged, return.
    /// 3. Swap the in-use registry, `activeMap`, and `player.currentItem`.
    /// 4. Seek to `sourceNow` through the **new** map.
    ///
    /// Call from: (a) Cadence toggle-off mid-play (spec §12); (b) WP9 tier-change ready.
    func applyCadenceChange() {
        guard let track = currentTrack else { return }

        // 1. Capture current source position BEFORE mutating activeMap.
        let sourceNow: Double
        if isSingleFile {
            sourceNow = bookTime   // bookTime already calls playerToSrc (uses old activeMap)
        } else {
            sourceNow = offsetInTrack   // multi-file: offsetInTrack is already source-domain
        }

        let wasPlaying = isPlaying

        // 2. Evaluate new selection.
        let newSelection = trimmedSource(for: track.fileRelPath)
        let newRelPath = newSelection?.relPath

        // No-op if already loaded the same source (nil == nil, or same relPath).
        if newRelPath == inUseTrimmedRelPath { return }

        // 3. Swap in-use registry.
        if let old = inUseTrimmedRelPath {
            CadenceInUseRegistry.shared.clearInUse(old)
            inUseTrimmedRelPath = nil
        }

        let newURL: URL
        if let sel = newSelection {
            newURL = sel.url
            activeMap = sel.map
            CadenceInUseRegistry.shared.markInUse(sel.relPath)
            inUseTrimmedRelPath = sel.relPath
        } else {
            guard let orig = try? ContainerPaths.url(forRelativePath: track.fileRelPath) else { return }
            newURL = orig
            activeMap = nil
        }

        // 4. Swap the player item and seek to the preserved source position.
        player.replaceCurrentItem(with: AVPlayerItem(url: newURL))

        if isSingleFile {
            // For single-file M4B: seek to the absolute book position using the new map.
            // The seek is issued immediately; AVPlayer queues it until the item is ready.
            seekSingleFile(to: sourceNow)
        } else {
            // Multi-file: seek within the current track file using the new map.
            player.seek(to: cmTime(srcToPlayer(sourceNow)))
            observeItemEnd()   // re-attach end observer to the new AVPlayerItem
        }

        if wasPlaying { player.rate = rate }
        updateNowPlaying()
    }

    private func seekSingleFile(to bookTime: Double) {
        player.seek(to: cmTime(srcToPlayer(bookTime)), toleranceBefore: .zero, toleranceAfter: .zero)
        recomputeIndex(forBookTime: bookTime)
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
                player.seek(to: cmTime(srcToPlayer(off)))
            }
            offsetInTrack = off
        }
        if isPlaying { player.rate = rate }
        updateNowPlaying()
    }

    // MARK: Observers

    private func addPeriodicObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        // Deliver on whatever queue AVFoundation uses and hop to the main actor.
        // `MainActor.assumeIsolated` here trips a dispatch-queue assertion even with
        // queue: .main, so hop explicitly with a Task instead.
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observeItemEnd()
    }

    private func observeItemEnd() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        // Deliver on the posting thread (queue: nil) and hop to the main actor
        // explicitly. NotificationCenter's `.main` is OperationQueue.main, which is
        // NOT libdispatch's main queue, so `MainActor.assumeIsolated` would trap.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnd() }
        }
    }

    private func tick() {
        let playerNow = player.currentTime().seconds
        guard playerNow.isFinite else { return }
        let now = playerToSrc(playerNow)   // map player (possibly trimmed) time → source domain
        if isSingleFile {
            recomputeIndex(forBookTime: now)
        } else {
            offsetInTrack = now
            // Single-file end is handled by recompute; multi-file by item-end notification.
        }
        updateNowPlayingElapsed()
        persist(force: false)
    }

    private func handleItemEnd() {
        if isSingleFile { return } // chapters are within one item
        if currentIndex + 1 < tracks.count {
            jump(toTrack: currentIndex + 1)
            if isPlaying { player.rate = rate }
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
        isSingleFile ? playerToSrc(player.currentTime().seconds) : prefixSums[currentIndex] + offsetInTrack
    }

    var totalDuration: Double { book?.totalDuration ?? prefixSums.last.map { $0 + (tracks.last?.duration ?? 0) } ?? 0 }

    // MARK: Persistence

    private func persist(force: Bool) {
        guard let book, let context else { return }
        if !force && Date().timeIntervalSince(lastPersist) < 5 { return }
        lastPersist = Date()
        book.lastTrackIndex = currentIndex
        book.lastOffsetSeconds = offsetInTrack
        try? context.save()
    }

    // MARK: Audio session + remote

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private func configureRemoteCommands() {
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
        info[MPMediaItemPropertyPlaybackDuration] = trackDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = offsetInTrack
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        if let coverRel = book?.coverPath,
           let url = try? ContainerPaths.url(forRelativePath: coverRel),
           let image = UIImage(contentsOfFile: url.path) {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(image)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Build the lock-screen artwork. `nonisolated` so its request handler is NOT
    /// main-actor-isolated — MediaPlayer invokes it on its own background queue,
    /// and a main-actor-isolated closure would trip an executor assertion there.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    private func updateNowPlayingElapsed() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] = offsetInTrack
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
    }

    // MARK: Static helpers

    private func cmTime(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }

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
/// Test seam for the WP5 headless self-test — exercises the REAL seek/read paths so it catches a
/// missed mapping site or an inverted direction (a pure map test cannot). Not compiled in release.
extension AudiobookPlayer {
    var debugItemReady: Bool { player.currentItem?.status == .readyToPlay }
    var debugIsTrimmed: Bool { activeMap != nil }
    /// Raw time on the loaded (possibly trimmed) `player` — for asserting it lands at `toTrimmed(S)`.
    var debugPlayerTimeSeconds: Double { player.currentTime().seconds }
    /// Source-domain position via the read path (`playerToSrc`) — for asserting it round-trips to S.
    var debugBookTime: Double { bookTime }
    func debugSeek(toSourceTime t: Double) { seekWithinBook(toBookTime: t) }
    /// WP10 test seam: expose `applyCadenceChange` to the self-test harness.
    func debugApplyCadenceChange() { applyCadenceChange() }
    /// WP8 test seam: arm the resume nudge flag and immediately trigger the nudge (without setting
    /// `isPlaying`). This lets the self-test drive the pure nudge logic deterministically without
    /// launching real playback.
    func debugSmartResumeNudge() {
        pendingResumeNudge = true
        pendingResumeNudge = false
        applySmartResumeNudge()
    }
}
#endif
