@preconcurrency import SoundAnalysis
import AVFoundation
import CoreMedia
import Foundation

/// Conservative SoundAnalysis adapter for identifying intervals that have enough evidence to be
/// considered music-only. Its output is deliberately not connected to playback or edit creation.
struct SemanticAudioClassifier: Sendable {
    struct Labels: Equatable, Sendable {
        let music: String
        let speech: String
        let singing: String

        var voiceLabels: Set<String> {
            [speech, singing]
        }

        /// Maps only exact, installed classifier labels. A classifier without distinct speech and
        /// singing outputs cannot demonstrate that a music window contains no voice.
        static func discover(in knownClassifications: [String]) -> Self? {
            let labels = Dictionary(
                knownClassifications.map { ($0.folding(options: [.caseInsensitive], locale: .current), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            guard let music = labels["music"],
                  let speech = labels["speech"],
                  let singing = labels["singing"]
            else {
                return nil
            }
            return .init(music: music, speech: speech, singing: singing)
        }
    }

    struct Window: Equatable, Sendable {
        let range: ClosedRange<TimeInterval>
        let musicConfidence: Double?
        let voiceConfidences: [String: Double]

        init(
            range: ClosedRange<TimeInterval>,
            musicConfidence: Double?,
            voiceConfidences: [String: Double]
        ) {
            self.range = range
            self.musicConfidence = musicConfidence
            self.voiceConfidences = voiceConfidences
        }
    }

    enum Analysis: Equatable, Sendable {
        case completed(coverage: ClosedRange<TimeInterval>)
        case incomplete(coverage: ClosedRange<TimeInterval>)
        case failed
        case cancelled

        var coverage: ClosedRange<TimeInterval>? {
            switch self {
            case let .completed(coverage), let .incomplete(coverage):
                coverage
            case .failed, .cancelled:
                nil
            }
        }
    }

    struct AdaptivePlan: Equatable, Sendable {
        let windows: [Window]
        let analysis: Analysis

        init(windows: [Window], analysis: Analysis) {
            self.windows = windows
            self.analysis = analysis
        }
    }

    struct Decision: Equatable, Sendable {
        let authorizedMusicOnlyRanges: [ClosedRange<TimeInterval>]
        let uncertainRanges: [ClosedRange<TimeInterval>]
        let isComplete: Bool

        static func failClosed(
            windows: [Window],
            coverage: ClosedRange<TimeInterval>? = nil,
            isComplete: Bool = false
        ) -> Self {
            .init(
                authorizedMusicOnlyRanges: [],
                uncertainRanges: normalize(windows.map(\.range) + (coverage.map { [$0] } ?? [])),
                isComplete: isComplete
            )
        }
    }

    struct Policy: Sendable {
        let minimumMusicConfidence: Double
        let maximumVoiceConfidence: Double
        let minimumSustainedMusicSeconds: TimeInterval
        let requiredVoiceLabels: Set<String>

        init(
            minimumMusicConfidence: Double = 0.95,
            maximumVoiceConfidence: Double = 0.02,
            minimumSustainedMusicSeconds: TimeInterval = 6,
            requiredVoiceLabels: Set<String> = ["Speech", "Singing"]
        ) {
            self.minimumMusicConfidence = minimumMusicConfidence
            self.maximumVoiceConfidence = maximumVoiceConfidence
            self.minimumSustainedMusicSeconds = minimumSustainedMusicSeconds
            self.requiredVoiceLabels = requiredVoiceLabels
        }

        /// An interval is authorized only when every overlapping classifier window supports music
        /// and independently supplies quiet values for each required voice label. Any failed,
        /// missing, low-confidence, speech, singing, or otherwise uncertain window protects its
        /// full reported time range.
        func decide(windows: [Window], analysis: Analysis) -> Decision {
            guard isValidConfiguration else {
                return .failClosed(windows: windows, coverage: analysis.coverage)
            }

            guard case let .completed(coverage) = analysis, isValid(coverage) else {
                return .failClosed(windows: windows, coverage: analysis.coverage)
            }

            let validWindows = windows.filter { isValid($0.range) && coverage.contains($0.range) }
            guard validWindows.count == windows.count,
                  SemanticAudioClassifier.windowsCoverSourceRange(validWindows, coverage: coverage)
            else {
                return .failClosed(windows: windows, coverage: coverage)
            }

            let evidence = validWindows.partitioned { supportsMusicOnly($0) }
            let qualifying = normalize(evidence.matching.map(\.range))
            let protected = normalize(evidence.nonMatching.map(\.range))
            let protectedMusic = subtract(qualifying, protected)
            let authorized = protectedMusic.filter {
                $0.upperBound - $0.lowerBound > minimumSustainedMusicSeconds
            }
            let tooShort = protectedMusic.filter {
                $0.upperBound - $0.lowerBound <= minimumSustainedMusicSeconds
            }

            return .init(
                authorizedMusicOnlyRanges: authorized,
                uncertainRanges: normalize(protected + tooShort),
                isComplete: true
            )
        }

        private var isValidConfiguration: Bool {
            minimumMusicConfidence.isFinite &&
                minimumMusicConfidence >= 0 &&
                minimumMusicConfidence <= 1 &&
                maximumVoiceConfidence.isFinite &&
                maximumVoiceConfidence >= 0 &&
                maximumVoiceConfidence <= 1 &&
                minimumSustainedMusicSeconds.isFinite &&
                minimumSustainedMusicSeconds > 0 &&
                !requiredVoiceLabels.isEmpty
        }

        private func supportsMusicOnly(_ window: Window) -> Bool {
            guard let musicConfidence = window.musicConfidence,
                  musicConfidence.isFinite,
                  (0...1).contains(musicConfidence),
                  musicConfidence >= minimumMusicConfidence
            else {
                return false
            }

            return requiredVoiceLabels.allSatisfy { label in
                guard let confidence = window.voiceConfidences[label],
                      confidence.isFinite,
                      (0...1).contains(confidence)
                else {
                    return false
                }
                return confidence <= maximumVoiceConfidence
            }
        }
    }

    private static func windowsCoverSourceRange(
        _ windows: [Window],
        coverage: ClosedRange<TimeInterval>
    ) -> Bool {
        guard !windows.isEmpty else { return false }
        let sorted = windows.sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard let first = sorted.first,
              first.range.lowerBound == coverage.lowerBound
        else {
            return false
        }

        var coveredThrough = first.range.upperBound
        for window in sorted.dropFirst() {
            guard window.range.lowerBound <= coveredThrough else { return false }
            coveredThrough = max(coveredThrough, window.range.upperBound)
        }
        return coveredThrough == coverage.upperBound
    }

    struct Configuration: Sendable {
        let preferredWindowDuration: TimeInterval
        let overlapFactor: Double
        let policy: Policy

        init(
            preferredWindowDuration: TimeInterval = 3,
            overlapFactor: Double = 0.5,
            policy: Policy = .init()
        ) {
            self.preferredWindowDuration = preferredWindowDuration
            self.overlapFactor = overlapFactor
            self.policy = policy
        }
    }

    /// Performs only file analysis. Call from a non-UI task. Cancellation, terminal request
    /// failure, unsupported labels, incomplete files, and ambiguous results return no authorizations.
    static func analyze(
        url: URL,
        configuration: Configuration = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> Decision {
        let result = await analyzeFile(
            url: url,
            configuration: configuration,
            isCancelled: isCancelled
        )
        guard let labels = result.labels,
              case let .completed(coverage) = result.plan.analysis
        else {
            return .failClosed(windows: result.plan.windows)
        }

        let policy = Policy(
            minimumMusicConfidence: configuration.policy.minimumMusicConfidence,
            maximumVoiceConfidence: configuration.policy.maximumVoiceConfidence,
            minimumSustainedMusicSeconds: configuration.policy.minimumSustainedMusicSeconds,
            requiredVoiceLabels: labels.voiceLabels
        )
        return policy.decide(windows: result.plan.windows, analysis: .completed(coverage: coverage))
    }

    /// Returns immutable source-time classifier evidence for adaptive playback. A file changed
    /// while it was analyzed, or any interrupted/incomplete analysis, is returned fail-closed.
    static func analyzeAdaptive(
        url: URL,
        configuration: Configuration = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> AdaptivePlan {
        guard let initialSnapshot = fileSnapshot(url: url) else {
            return .init(windows: [], analysis: .failed)
        }

        let result = await analyzeFile(
            url: url,
            configuration: configuration,
            isCancelled: isCancelled
        )
        guard case let .completed(coverage) = result.plan.analysis else {
            return result.plan
        }
        guard fileSnapshot(url: url) == initialSnapshot else {
            return .init(windows: result.plan.windows, analysis: .incomplete(coverage: coverage))
        }

        return result.plan
    }

    /// Analyzes only a bounded source-time interval for live adaptive playback. The stream analyzer
    /// reads small buffers and never holds decoded audio for the entire file in memory.
    static func analyzeAdaptive(
        url: URL,
        sourceRange: ClosedRange<TimeInterval>,
        maximumDuration: TimeInterval = 30,
        configuration: Configuration = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async -> AdaptivePlan {
        guard !Task.isCancelled, !isCancelled(),
              sourceRange.lowerBound.isFinite,
              sourceRange.upperBound.isFinite,
              sourceRange.lowerBound >= 0,
              sourceRange.upperBound > sourceRange.lowerBound,
              maximumDuration.isFinite,
              maximumDuration > 0,
              sourceRange.upperBound - sourceRange.lowerBound <= maximumDuration,
              configuration.preferredWindowDuration.isFinite,
              configuration.preferredWindowDuration > 0,
              configuration.overlapFactor >= 0,
              configuration.overlapFactor < 1,
              let initialSnapshot = fileSnapshot(url: url),
              let file = try? AVAudioFile(forReading: url)
        else {
            return .init(windows: [], analysis: .failed)
        }

        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            return .init(windows: [], analysis: .failed)
        }
        let firstFrame = max(0, Int64((sourceRange.lowerBound * sampleRate).rounded(.down)))
        let lastFrame = min(file.length, Int64((sourceRange.upperBound * sampleRate).rounded(.up)))
        guard lastFrame > firstFrame else {
            return .init(windows: [], analysis: .failed)
        }
        let coverage = (Double(firstFrame) / sampleRate)...(Double(lastFrame) / sampleRate)

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            guard let labels = Labels.discover(in: request.knownClassifications),
                  let duration = supportedDuration(
                    for: request.windowDurationConstraint,
                    preferred: configuration.preferredWindowDuration
                  )
            else {
                return .init(windows: [], analysis: .failed)
            }
            request.windowDuration = duration
            request.overlapFactor = configuration.overlapFactor

            let analyzer = SNAudioStreamAnalyzer(format: file.processingFormat)
            let observer = Observer(labels: labels)
            try analyzer.add(request, withObserver: observer)
            file.framePosition = firstFrame

            var framePosition = firstFrame
            while framePosition < lastFrame {
                guard !Task.isCancelled, !isCancelled() else {
                    return .init(windows: observer.windows, analysis: .cancelled)
                }
                let framesToRead = AVAudioFrameCount(min(8_192, lastFrame - framePosition))
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: framesToRead
                ) else {
                    return .init(windows: observer.windows, analysis: .failed)
                }
                try file.read(into: buffer, frameCount: framesToRead)
                guard buffer.frameLength > 0 else { break }
                analyzer.analyze(buffer, atAudioFramePosition: framePosition)
                framePosition += Int64(buffer.frameLength)
            }
            guard framePosition == lastFrame else {
                return .init(
                    windows: observer.windows,
                    analysis: .incomplete(coverage: coverage)
                )
            }
            analyzer.completeAnalysis()

            let windows = observer.windows.compactMap { window -> Window? in
                let lower = max(window.range.lowerBound, coverage.lowerBound)
                let upper = min(window.range.upperBound, coverage.upperBound)
                guard upper > lower else { return nil }
                return .init(
                    range: lower...upper,
                    musicConfidence: window.musicConfidence,
                    voiceConfidences: window.voiceConfidences
                )
            }
            guard !Task.isCancelled, !isCancelled() else {
                return .init(windows: windows, analysis: .cancelled)
            }
            guard !observer.failed, fileSnapshot(url: url) == initialSnapshot else {
                return .init(windows: windows, analysis: .incomplete(coverage: coverage))
            }
            guard Self.windowsCoverSourceRange(windows, coverage: coverage) else {
                return .init(windows: windows, analysis: .incomplete(coverage: coverage))
            }
            return .init(windows: windows, analysis: .completed(coverage: coverage))
        } catch {
            return .init(windows: [], analysis: .failed)
        }
    }

    private struct FileAnalysis: Sendable {
        let plan: AdaptivePlan
        let labels: Labels?
    }

    private struct FileSnapshot: Equatable {
        let fileSize: UInt64
        let modificationDate: Date
        let duration: TimeInterval
    }

    private static func analyzeFile(
        url: URL,
        configuration: Configuration,
        isCancelled: @escaping @Sendable () -> Bool
    ) async -> FileAnalysis {
        guard !Task.isCancelled, !isCancelled(),
              configuration.preferredWindowDuration.isFinite,
              configuration.preferredWindowDuration > 0,
              configuration.overlapFactor >= 0,
              configuration.overlapFactor < 1
        else {
            return .init(plan: .init(windows: [], analysis: .cancelled), labels: nil)
        }

        do {
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            guard let labels = Labels.discover(in: request.knownClassifications) else {
                return .init(plan: .init(windows: [], analysis: .failed), labels: nil)
            }
            guard let duration = supportedDuration(
                for: request.windowDurationConstraint,
                preferred: configuration.preferredWindowDuration
            ) else {
                return .init(plan: .init(windows: [], analysis: .failed), labels: nil)
            }
            request.windowDuration = duration
            request.overlapFactor = configuration.overlapFactor

            let analyzer = try SNAudioFileAnalyzer(url: url)
            let observer = Observer(labels: labels)
            try analyzer.add(request, withObserver: observer)

            let cancellationMonitor = Task {
                while !Task.isCancelled {
                    if isCancelled() {
                        analyzer.cancelAnalysis()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { cancellationMonitor.cancel() }

            let reachedEndOfFile = await withTaskCancellationHandler(
                operation: {
                    await withCheckedContinuation { continuation in
                        analyzer.analyze { didReachEndOfFile in
                            continuation.resume(returning: didReachEndOfFile)
                        }
                    }
                },
                onCancel: {
                    analyzer.cancelAnalysis()
                }
            )

            let windows = observer.windows
            guard !Task.isCancelled, !isCancelled() else {
                return .init(plan: .init(windows: windows, analysis: .cancelled), labels: labels)
            }
            guard reachedEndOfFile else {
                let analysis: Analysis
                if let range = observedCoverage(windows) {
                    analysis = .incomplete(coverage: range)
                } else {
                    analysis = .failed
                }
                return .init(plan: .init(windows: windows, analysis: analysis), labels: labels)
            }
            guard !observer.failed else {
                return .init(plan: .init(windows: windows, analysis: .failed), labels: labels)
            }
            guard let coverage = fileCoverage(url: url) else {
                return .init(plan: .init(windows: windows, analysis: .failed), labels: labels)
            }
            guard Self.windowsCoverSourceRange(windows, coverage: coverage) else {
                let analysis = observedCoverage(windows).map(Analysis.incomplete(coverage:)) ?? .failed
                return .init(plan: .init(windows: windows, analysis: analysis), labels: labels)
            }
            return .init(
                plan: .init(windows: windows, analysis: .completed(coverage: coverage)),
                labels: labels
            )
        } catch {
            return .init(plan: .init(windows: [], analysis: .failed), labels: nil)
        }
    }

    private static func fileSnapshot(url: URL) -> FileSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.uint64Value > 0,
              let modificationDate = attributes[.modificationDate] as? Date,
              let coverage = fileCoverage(url: url)
        else {
            return nil
        }
        return .init(
            fileSize: fileSize.uint64Value,
            modificationDate: modificationDate,
            duration: coverage.upperBound
        )
    }

    private static func observedCoverage(_ windows: [Window]) -> ClosedRange<TimeInterval>? {
        let ranges = windows.map(\.range).filter(isValid).sorted {
            $0.lowerBound < $1.lowerBound
        }
        guard let first = ranges.first,
              let last = ranges.last
        else {
            return nil
        }
        return first.lowerBound...last.upperBound
    }

    private static func supportedDuration(
        for constraint: SNTimeDurationConstraint,
        preferred: TimeInterval
    ) -> CMTime? {
        switch constraint {
        case let .enumeratedDurations(durations):
            return durations
                .filter { $0.isValid && $0.seconds.isFinite && $0.seconds > 0 }
                .min { abs($0.seconds - preferred) < abs($1.seconds - preferred) }
        case let .durationRange(range):
            guard range.start.isValid,
                  range.duration.isValid,
                  range.start.seconds.isFinite,
                  range.duration.seconds.isFinite,
                  range.duration.seconds >= 0
            else {
                return nil
            }
            let lower = range.start.seconds
            let upper = lower + range.duration.seconds
            let seconds = min(max(preferred, lower), upper)
            guard seconds.isFinite, seconds > 0 else { return nil }
            return CMTime(seconds: seconds, preferredTimescale: 1_000)
        @unknown default:
            return nil
        }
    }

    private static func fileCoverage(url: URL) -> ClosedRange<TimeInterval>? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 0
        else {
            return nil
        }

        guard let asset = try? AVAudioFile(forReading: url) else { return nil }
        let duration = Double(asset.length) / asset.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { return nil }
        return 0...duration
    }

    private final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let labels: Labels
        private let lock = NSLock()
        private var storedWindows: [Window] = []
        private var didFail = false

        init(labels: Labels) {
            self.labels = labels
        }

        var windows: [Window] {
            lock.withLock { storedWindows }
        }

        var failed: Bool {
            lock.withLock { didFail }
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let range = result.timeRange
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end > start else { return }

            let confidences = Dictionary(
                result.classifications.map { ($0.identifier, $0.confidence) },
                uniquingKeysWith: { max($0, $1) }
            )
            let window = Window(
                range: start...end,
                musicConfidence: confidences[labels.music],
                voiceConfidences: [
                    labels.speech: confidences[labels.speech],
                    labels.singing: confidences[labels.singing]
                ].compactMapValues { $0 }
            )
            lock.withLock {
                storedWindows.append(window)
            }
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            lock.withLock {
                didFail = true
            }
        }
    }
}

private extension Array where Element == SemanticAudioClassifier.Window {
    func partitioned(
        by predicate: (Element) -> Bool
    ) -> (matching: [Element], nonMatching: [Element]) {
        reduce(into: (matching: [], nonMatching: [])) { result, element in
            if predicate(element) {
                result.matching.append(element)
            } else {
                result.nonMatching.append(element)
            }
        }
    }
}

private func isValid(_ range: ClosedRange<TimeInterval>) -> Bool {
    range.lowerBound.isFinite &&
        range.upperBound.isFinite &&
        range.upperBound > range.lowerBound
}

private func normalize(_ ranges: [ClosedRange<TimeInterval>]) -> [ClosedRange<TimeInterval>] {
    let sorted = ranges.filter(isValid).sorted { $0.lowerBound < $1.lowerBound }
    guard var current = sorted.first else { return [] }
    var result: [ClosedRange<TimeInterval>] = []

    for range in sorted.dropFirst() {
        if range.lowerBound <= current.upperBound {
            current = current.lowerBound...max(current.upperBound, range.upperBound)
        } else {
            result.append(current)
            current = range
        }
    }
    result.append(current)
    return result
}

private func subtract(
    _ ranges: [ClosedRange<TimeInterval>],
    _ protectedRanges: [ClosedRange<TimeInterval>]
) -> [ClosedRange<TimeInterval>] {
    protectedRanges.reduce(ranges) { remaining, protectedRange in
        remaining.flatMap { range -> [ClosedRange<TimeInterval>] in
            guard protectedRange.lowerBound < range.upperBound,
                  protectedRange.upperBound > range.lowerBound
            else {
                return [range]
            }

            var pieces: [ClosedRange<TimeInterval>] = []
            if protectedRange.lowerBound > range.lowerBound {
                pieces.append(range.lowerBound...min(range.upperBound, protectedRange.lowerBound))
            }
            if protectedRange.upperBound < range.upperBound {
                pieces.append(max(range.lowerBound, protectedRange.upperBound)...range.upperBound)
            }
            return pieces.filter(isValid)
        }
    }
}
