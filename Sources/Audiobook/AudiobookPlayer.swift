import AVFoundation
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
    }

    /// Persist position and stop. Call when leaving the player.
    func teardown() {
        persist(force: true)
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    // MARK: Transport

    func togglePlayPause() { isPlaying ? pause() : play() }

    func play() {
        isPlaying = true
        player.rate = rate
        updateNowPlaying()
    }

    func pause() {
        isPlaying = false
        player.pause()
        persist(force: true)
        updateNowPlaying()
    }

    /// Skip relative seconds within the book (crosses track boundaries).
    func skip(_ seconds: Double) {
        seekWithinBook(toBookTime: bookTime + seconds)
    }

    /// Seek within the current track (0...trackDuration).
    func seekInTrack(to seconds: Double) {
        let clamped = min(max(seconds, 0), trackDuration)
        if isSingleFile {
            seekSingleFile(to: prefixSums[currentIndex] + clamped)
        } else {
            player.seek(to: cmTime(clamped))
            offsetInTrack = clamped
        }
        updateNowPlaying()
    }

    func jump(toTrack index: Int) {
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
        guard let track = currentTrack,
              let url = try? ContainerPaths.url(forRelativePath: track.fileRelPath) else { return }
        if isSingleFile {
            // Load the shared file once; seek to absolute book position.
            if player.currentItem == nil {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
            }
            seekSingleFile(to: prefixSums[currentIndex] + offset)
        } else {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            player.seek(to: cmTime(offset))
            observeItemEnd()
        }
    }

    private func seekSingleFile(to bookTime: Double) {
        player.seek(to: cmTime(bookTime), toleranceBefore: .zero, toleranceAfter: .zero)
        recomputeIndex(forBookTime: bookTime)
    }

    private func seekWithinBook(toBookTime t: Double) {
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
                player.seek(to: cmTime(off))
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
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
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
        isSingleFile ? player.currentTime().seconds : prefixSums[currentIndex] + offsetInTrack
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
