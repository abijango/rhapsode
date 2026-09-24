import Foundation

enum SmartSpeechDiagnosticEvent: Sendable {
    enum PrescanStatus: String, Sendable {
        case started
        case progress
        case completed
        case cancelled
    }

    enum PrescanFallback: String, Sendable {
        case none
        case rolling
    }

    enum ProducerMode: Sendable {
        case mapped
        case rollingFallback
        case original

        fileprivate var formatted: String {
            switch self {
            case .mapped: "mapped"
            case .rollingFallback: "rolling_fallback"
            case .original: "original"
            }
        }
    }

    enum PlaybackRemovalKind: String, Hashable, Sendable {
        case pause
        case music
    }

    case prescan(status: PrescanStatus, analyzedSeconds: Double,
                 sourceSeconds: Double, fallback: PrescanFallback)
    case producer(mode: ProducerMode, candidatePauseSeconds: Double,
                  candidateMusicSeconds: Double, realizedPauseSeconds: Double,
                  realizedMusicSeconds: Double, lowAhead: Bool)
    case playbackRemoval(kind: PlaybackRemovalKind, seconds: Double)

    var coverage: Double {
        guard case let .prescan(_, analyzedSeconds, sourceSeconds, _) = self else { return 0 }
        guard analyzedSeconds.isFinite, sourceSeconds.isFinite, sourceSeconds > 0 else { return 0 }
        return analyzedSeconds / sourceSeconds
    }

    var formatted: String {
        switch self {
        case let .prescan(status, analyzedSeconds, sourceSeconds, fallback):
            return "prescan status=\(status.rawValue) analyzed_s=\(Self.seconds(analyzedSeconds)) source_s=\(Self.seconds(sourceSeconds)) coverage=\(Self.coverageString(coverage)) fallback=\(fallback.rawValue)"
        case let .producer(mode, candidatePauseSeconds, candidateMusicSeconds,
                           realizedPauseSeconds, realizedMusicSeconds, lowAhead):
            return "producer mode=\(mode.formatted) candidate_pause_s=\(Self.seconds(candidatePauseSeconds)) candidate_music_s=\(Self.seconds(candidateMusicSeconds)) realized_pause_s=\(Self.seconds(realizedPauseSeconds)) realized_music_s=\(Self.seconds(realizedMusicSeconds)) low_ahead=\(lowAhead ? 1 : 0)"
        case let .playbackRemoval(kind, seconds):
            return "playback_removal kind=\(kind.rawValue) seconds=\(Self.seconds(seconds))"
        }
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func seconds(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let fixed = String(format: "%.3f", locale: posixLocale, value)
        guard fixed.contains(".") else { return fixed }
        return fixed.replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func coverageString(_ value: Double) -> String {
        guard value.isFinite else { return "0.000" }
        return String(format: "%.3f", locale: posixLocale, value)
    }
}

struct SmartSpeechDiagnosticSummary: Sendable {
    private let capacity: Int
    private(set) var events: [SmartSpeechDiagnosticEvent] = []
    private(set) var droppedEventCount = 0
    private(set) var cancelledPrescanCount = 0
    private(set) var cancelledPrescanAnalyzedSeconds: Double = 0
    private var removedSeconds: [SmartSpeechDiagnosticEvent.PlaybackRemovalKind: Double] = [:]

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    mutating func record(_ event: SmartSpeechDiagnosticEvent) {
        switch event {
        case let .prescan(status: .cancelled, analyzedSeconds, _, _):
            cancelledPrescanCount += 1
            cancelledPrescanAnalyzedSeconds += analyzedSeconds.isFinite ? analyzedSeconds : 0
        case let .playbackRemoval(kind, seconds):
            removedSeconds[kind, default: 0] += seconds.isFinite ? seconds : 0
        default:
            break
        }

        guard capacity > 0 else {
            droppedEventCount += 1
            return
        }
        if events.count == capacity {
            events.removeFirst()
            droppedEventCount += 1
        }
        events.append(event)
    }

    func realizedRemovedSeconds(for kind: SmartSpeechDiagnosticEvent.PlaybackRemovalKind) -> Double {
        removedSeconds[kind, default: 0]
    }
}
