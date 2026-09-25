import Foundation

public enum SemanticAudioKind: String, Codable, Sendable {
    case speech
    case breath
    case silence
    case roomTone
    case musicOnly
    case speechOverMusic
    case singing
    case soundEffect
    case uncertain
}

public struct SemanticRegion: Equatable, Codable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let kind: SemanticAudioKind
    public let confidence: Double

    public var duration: TimeInterval { max(0, end - start) }

    public init(start: TimeInterval, end: TimeInterval,
                kind: SemanticAudioKind, confidence: Double) {
        self.start = start
        self.end = end
        self.kind = kind
        self.confidence = confidence
    }
}

public enum AudioEditKind: String, Codable, Sendable {
    case compressPause
    case removeMusic
}

public struct AudioEdit: Equatable, Codable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let kind: AudioEditKind

    public init(start: TimeInterval, end: TimeInterval, kind: AudioEditKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public struct SemanticEditPolicy: Equatable, Codable, Sendable {
    /// Governs compressPause amount/placement — identical math to the legacy silence path
    /// (`SilencePolicy.target`), so live semantic edits match `TrimRenderer.renderMapped` /
    /// the `cadence` CLI oracle exactly for the same input + tier.
    public var silenceSettings: SmartSpeechSettings
    public var minimumMusicDuration: TimeInterval
    public var musicLeadingHandle: TimeInterval
    public var musicTrailingHandle: TimeInterval
    public var minimumConfidence: Double

    public init(
        silenceSettings: SmartSpeechSettings = SmartSpeechSettings(),
        minimumMusicDuration: TimeInterval = 3.0,
        musicLeadingHandle: TimeInterval = 0.25,
        musicTrailingHandle: TimeInterval = 0.35,
        minimumConfidence: Double = 0.70
    ) {
        self.silenceSettings = silenceSettings
        self.minimumMusicDuration = minimumMusicDuration
        self.musicLeadingHandle = musicLeadingHandle
        self.musicTrailingHandle = musicTrailingHandle
        self.minimumConfidence = minimumConfidence
    }
}

/// Converts semantic source-time regions into exact intervals to remove. Speech protection is
/// deliberately fail-open: only confident silence/room-tone or sustained music-only regions edit.
public struct SemanticEditPlanner: Sendable {
    public let policy: SemanticEditPolicy

    public init(policy: SemanticEditPolicy = SemanticEditPolicy()) {
        self.policy = policy
    }

    public func edits(for regions: [SemanticRegion]) -> [AudioEdit] {
        let candidates = regions.compactMap(edit(for:))
        return PlaybackEditMap(edits: candidates).edits
    }

    private func edit(for region: SemanticRegion) -> AudioEdit? {
        guard region.duration > 0, region.confidence >= policy.minimumConfidence else { return nil }
        switch region.kind {
        case .silence, .roomTone:
            // Same D→target mapping and the same kept-silence placement (leading, trailing
            // tail removed) as `TrimRenderer.plan`, so this never drifts from the CLI oracle.
            let target = SilencePolicy.target(forSilenceDuration: region.duration, settings: policy.silenceSettings)
            let removable = region.duration - target
            guard removable > 0 else { return nil }
            let start = region.start + target
            return AudioEdit(start: start, end: start + removable, kind: .compressPause)

        case .musicOnly:
            guard region.duration >= policy.minimumMusicDuration else { return nil }
            let start = region.start + policy.musicLeadingHandle
            let end = region.end - policy.musicTrailingHandle
            guard end > start else { return nil }
            return AudioEdit(start: start, end: end, kind: .removeMusic)

        case .speech, .breath, .speechOverMusic, .singing, .soundEffect, .uncertain:
            return nil
        }
    }
}

/// Stable source-domain decisions. Chunk renderers ask for local removal intervals, so a pause
/// crossing a decode seam receives one global policy decision instead of being shortened twice.
public struct PlaybackEditMap: Equatable, Codable, Sendable {
    public let edits: [AudioEdit]

    public init(edits: [AudioEdit]) {
        let valid = edits
            .filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var merged: [AudioEdit] = []
        for edit in valid {
            if let last = merged.last, edit.start <= last.end, edit.kind == last.kind {
                merged[merged.count - 1] = AudioEdit(
                    start: last.start, end: max(last.end, edit.end), kind: last.kind
                )
            } else {
                merged.append(edit)
            }
        }
        self.edits = merged
    }

    public func removals(in sourceRange: Range<TimeInterval>) -> [SilenceRegion] {
        edits.compactMap { edit in
            let start = max(edit.start, sourceRange.lowerBound)
            let end = min(edit.end, sourceRange.upperBound)
            guard end > start else { return nil }
            return SilenceRegion(
                start: start - sourceRange.lowerBound,
                end: end - sourceRange.lowerBound
            )
        }
    }

    /// Avoid placing a decode/render seam inside a finalized edit. This ensures an edit is rendered
    /// atomically and prevents a chunk-local renderer from seeing a removal that begins at frame 0.
    /// Loops to a fixpoint: pushing past one edit can land inside the next (e.g. a short compressPause
    /// immediately followed by another edit), so a single hop is not enough to guarantee a clean seam.
    public func renderEnd(from start: TimeInterval, preferredEnd: TimeInterval,
                          sourceEnd: TimeInterval) -> TimeInterval {
        guard preferredEnd < sourceEnd else { return sourceEnd }
        var end = preferredEnd
        while let containing = edits.first(where: {
            $0.start < end && $0.end > end && $0.end > start
        }) {
            let next = min(containing.end, sourceEnd)
            guard next > end else { break } // no progress — avoid looping on a degenerate edit
            end = next
        }
        return end
    }
}
