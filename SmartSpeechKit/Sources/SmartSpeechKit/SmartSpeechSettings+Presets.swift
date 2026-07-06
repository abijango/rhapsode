import Foundation

public extension SmartSpeechSettings {
    /// User-facing trimming sensitivity. Drop this into the app as the single setting the
    /// user picks; each case maps to a full `SmartSpeechSettings`. The progression only pushes
    /// the *safe* levers hard (collapse long dead gaps harder, touch slightly shorter gaps)
    /// and nudges the risky ones (detection margin, edge guard) gently — so even `aggressive`
    /// stays clear of chopped breaths and clicks.
    enum Preset: String, CaseIterable, Codable, Sendable {
        /// Conservative-natural — the spec defaults ("you forget it's on").
        case `default`
        /// Noticeably more savings, still safe — long gaps collapse harder, shorter gaps eligible.
        case more
        /// Maximum savings while staying click-free; pauses get tight and it feels faster.
        case aggressive

        public var displayName: String {
            switch self {
            case .default: return "Default"
            case .more: return "More"
            case .aggressive: return "Aggressive"
            }
        }
    }

    /// Build settings for a preset.
    init(preset: Preset) {
        switch preset {
        case .default:
            self = SmartSpeechSettings()
        case .more:
            self = SmartSpeechSettings(minSilenceDuration: 0.24, minKeptSilence: 0.15,
                                   residualSlope: 0.08, thresholdMarginDb: 9.0,
                                   edgeGuardMs: 38, crossfadeMs: 15)
        case .aggressive:
            self = SmartSpeechSettings(minSilenceDuration: 0.20, minKeptSilence: 0.12,
                                   residualSlope: 0.05, thresholdMarginDb: 10.0,
                                   edgeGuardMs: 32, crossfadeMs: 18)
        }
    }
}
