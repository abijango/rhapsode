import Foundation

struct AdaptiveSpeedPolicy: Sendable {
    private static let minimumSpeechConfidence = 0.95
    private static let maximumMusicConfidenceForSpeech = 0.02
    private static let maximumSingingConfidenceForSpeech = 0.02
    private static let minimumSustainedSpeechDuration: TimeInterval = 6
    private static let speechRateIncrease = 0.15
    private static let maximumPlaybackRate = 3.0

    let isEnabled: Bool

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func playbackRate(
        selectedRate: Double,
        windows: [SemanticAudioClassifier.Window],
        analysis: SemanticAudioClassifier.Analysis
    ) -> Double {
        guard case let .completed(coverage) = analysis else {
            return Self.rateAfterFailure(selectedRate: selectedRate)
        }
        return playbackRate(
            selectedRate: selectedRate,
            windows: windows,
            analysis: analysis,
            sourceRange: coverage
        )
    }

    func playbackRate(
        selectedRate: Double,
        windows: [SemanticAudioClassifier.Window],
        analysis: SemanticAudioClassifier.Analysis,
        sourceRange: ClosedRange<TimeInterval>
    ) -> Double {
        guard isEnabled,
              case let .completed(coverage) = analysis,
              isValid(coverage),
              isValid(sourceRange),
              coverage.contains(sourceRange.lowerBound),
              coverage.contains(sourceRange.upperBound)
        else {
            return Self.rateAfterFailure(selectedRate: selectedRate)
        }

        guard selectedRate.isFinite else {
            return Self.rateAfterFailure(selectedRate: selectedRate)
        }

        let scopedWindows = windows.compactMap { window -> SemanticAudioClassifier.Window? in
            let lower = max(window.range.lowerBound, sourceRange.lowerBound)
            let upper = min(window.range.upperBound, sourceRange.upperBound)
            guard upper > lower else { return nil }
            return .init(
                range: lower...upper,
                musicConfidence: window.musicConfidence,
                voiceConfidences: window.voiceConfidences
            )
        }
        guard hasCompleteCoverage(scopedWindows, within: sourceRange) else {
            return Self.rateAfterFailure(selectedRate: selectedRate)
        }

        if scopedWindows.allSatisfy(isMusicOnly) {
            return 1.0
        }

        guard scopedWindows.allSatisfy(isPureSpeech),
              sourceRange.upperBound - sourceRange.lowerBound >= Self.minimumSustainedSpeechDuration
        else {
            return selectedRate
        }

        return min(selectedRate + Self.speechRateIncrease, Self.maximumPlaybackRate)
    }

    static func rateAfterFailure(selectedRate: Double) -> Double {
        selectedRate
    }

    private func isMusicOnly(_ window: SemanticAudioClassifier.Window) -> Bool {
        guard let music = confidence(in: window, for: "Music"),
              let speech = confidence(in: window, for: "Speech"),
              let singing = confidence(in: window, for: "Singing")
        else {
            return false
        }

        return music >= Self.minimumSpeechConfidence &&
            speech <= Self.maximumMusicConfidenceForSpeech &&
            singing <= Self.maximumSingingConfidenceForSpeech
    }

    private func isPureSpeech(_ window: SemanticAudioClassifier.Window) -> Bool {
        guard let music = confidence(in: window, for: "Music"),
              let speech = confidence(in: window, for: "Speech"),
              let singing = confidence(in: window, for: "Singing")
        else {
            return false
        }

        return speech >= Self.minimumSpeechConfidence &&
            music <= Self.maximumMusicConfidenceForSpeech &&
            singing <= Self.maximumSingingConfidenceForSpeech
    }

    private func confidence(in window: SemanticAudioClassifier.Window, for label: String) -> Double? {
        if label == "Music" {
            guard let value = window.musicConfidence,
                  value.isFinite,
                  (0...1).contains(value)
            else {
                return nil
            }
            return value
        }

        guard let value = window.voiceConfidences.first(where: {
            $0.key.compare(label, options: [.caseInsensitive]) == .orderedSame
        })?.value,
              value.isFinite,
              (0...1).contains(value)
        else {
            return nil
        }
        return value
    }

    private func hasCompleteCoverage(
        _ windows: [SemanticAudioClassifier.Window],
        within coverage: ClosedRange<TimeInterval>
    ) -> Bool {
        guard !windows.isEmpty else { return false }

        let sorted = windows.sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard sorted.allSatisfy({
            isValid($0.range) && coverage.contains($0.range)
        }),
        let first = sorted.first,
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

    private func isValid(_ range: ClosedRange<TimeInterval>) -> Bool {
        range.lowerBound.isFinite &&
            range.upperBound.isFinite &&
            range.upperBound > range.lowerBound
    }
}
