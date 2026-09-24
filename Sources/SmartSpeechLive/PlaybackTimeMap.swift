import Foundation

struct Checkpoint: Equatable, Sendable {
    let playbackTime: TimeInterval
    let contentTime: TimeInterval
}

struct PlaybackTimeMap: Sendable {
    let checkpoints: [Checkpoint]
    let playbackDuration: TimeInterval
    let contentDuration: TimeInterval
    /// True when checkpoint alignment is estimated rather than an exact timeline pair.
    let mappingIsEstimated: Bool

    init(progress: [RubberBandStream.PushProgress], sampleRate: Double) {
        guard sampleRate.isFinite, sampleRate > 0,
              let latest = progress.last else {
            self.init(checkpoints: [], playbackDuration: 0, contentDuration: 0,
                      mappingIsEstimated: true)
            return
        }

        let checkpoints = progress.map {
            Checkpoint(
                playbackTime: Double($0.cumulativeTargetOutputFrames) / sampleRate,
                contentTime: Double($0.cumulativeInputFrames) / sampleRate
            )
        }
        self.init(
            checkpoints: checkpoints,
            playbackDuration: Double(latest.cumulativeTargetOutputFrames) / sampleRate,
            contentDuration: Double(latest.cumulativeInputFrames) / sampleRate,
            mappingIsEstimated: true
        )
    }

    init(
        checkpoints: [Checkpoint],
        playbackDuration: TimeInterval,
        contentDuration: TimeInterval,
        mappingIsEstimated: Bool = false
    ) {
        let safePlaybackDuration = Self.validDuration(playbackDuration)
        let safeContentDuration = Self.validDuration(contentDuration)
        self.playbackDuration = safePlaybackDuration
        self.contentDuration = safeContentDuration
        self.mappingIsEstimated = mappingIsEstimated

        guard safePlaybackDuration > 0, safeContentDuration > 0 else {
            self.checkpoints = [Checkpoint(playbackTime: 0, contentTime: 0)]
            return
        }

        let interior = checkpoints
            .filter { $0.playbackTime.isFinite && $0.contentTime.isFinite }
            .map {
                Checkpoint(
                    playbackTime: min(max($0.playbackTime, 0), safePlaybackDuration),
                    contentTime: min(max($0.contentTime, 0), safeContentDuration)
                )
            }
            .filter {
                $0.playbackTime > 0 && $0.playbackTime < safePlaybackDuration
                    && $0.contentTime > 0 && $0.contentTime < safeContentDuration
            }
            .sorted {
                if $0.playbackTime == $1.playbackTime {
                    return $0.contentTime > $1.contentTime
                }
                return $0.playbackTime < $1.playbackTime
            }

        var normalized = [Checkpoint(playbackTime: 0, contentTime: 0)]
        for checkpoint in interior {
            guard let previous = normalized.last,
                  checkpoint.playbackTime > previous.playbackTime,
                  checkpoint.contentTime > previous.contentTime else {
                continue
            }
            normalized.append(checkpoint)
        }
        normalized.append(
            Checkpoint(playbackTime: safePlaybackDuration, contentTime: safeContentDuration)
        )
        self.checkpoints = normalized
    }

    func contentTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval {
        interpolate(
            playbackTime.isNaN ? 0 : playbackTime,
            from: \Checkpoint.playbackTime,
            to: \Checkpoint.contentTime,
            inputDuration: playbackDuration,
            outputDuration: contentDuration
        )
    }

    func playbackTime(forContentTime contentTime: TimeInterval) -> TimeInterval {
        interpolate(
            contentTime.isNaN ? 0 : contentTime,
            from: \Checkpoint.contentTime,
            to: \Checkpoint.playbackTime,
            inputDuration: contentDuration,
            outputDuration: playbackDuration
        )
    }

    /// Returns a lookup only when the timeline was built from exact checkpoints.
    /// This fails closed for Rubber Band streaming checkpoints affected by output latency.
    func exactContentTime(forPlaybackTime playbackTime: TimeInterval) -> TimeInterval? {
        guard !mappingIsEstimated else { return nil }
        return contentTime(forPlaybackTime: playbackTime)
    }

    /// Returns a lookup only when the timeline was built from exact checkpoints.
    func exactPlaybackTime(forContentTime contentTime: TimeInterval) -> TimeInterval? {
        guard !mappingIsEstimated else { return nil }
        return playbackTime(forContentTime: contentTime)
    }

    private func interpolate(
        _ value: TimeInterval,
        from input: KeyPath<Checkpoint, TimeInterval>,
        to output: KeyPath<Checkpoint, TimeInterval>,
        inputDuration: TimeInterval,
        outputDuration: TimeInterval
    ) -> TimeInterval {
        guard inputDuration > 0, outputDuration > 0 else { return 0 }
        let bounded = min(max(value, 0), inputDuration)
        guard bounded > 0 else { return 0 }
        guard bounded < inputDuration else { return outputDuration }

        var lowerIndex = 0
        var upperIndex = checkpoints.count - 1
        while upperIndex - lowerIndex > 1 {
            let middleIndex = (lowerIndex + upperIndex) / 2
            if checkpoints[middleIndex][keyPath: input] <= bounded {
                lowerIndex = middleIndex
            } else {
                upperIndex = middleIndex
            }
        }

        let lower = checkpoints[lowerIndex]
        let upper = checkpoints[upperIndex]
        let span = upper[keyPath: input] - lower[keyPath: input]
        guard span > 0 else { return lower[keyPath: output] }
        let fraction = (bounded - lower[keyPath: input]) / span
        return lower[keyPath: output] + fraction * (upper[keyPath: output] - lower[keyPath: output])
    }

    private static func validDuration(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite ? max(0, duration) : 0
    }
}
