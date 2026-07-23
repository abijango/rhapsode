import Foundation

/// In-session reading appearance (theme / typeface / size). Persists via `ReaderPreferences`.
struct ReaderSettings: Equatable {
    enum ReaderTheme: String, CaseIterable, Identifiable {
        case light, dark, sepia
        var id: String { rawValue }
    }

    var fontChoice: ReaderFontChoice = .literata
    var fontSize: Double = 1.0
    var theme: ReaderTheme = .light

    static func fromPreferences() -> ReaderSettings {
        ReaderSettings(
            fontChoice: ReaderPreferences.fontChoice,
            fontSize: ReaderPreferences.fontSize,
            theme: ReaderPreferences.theme
        )
    }

    func saveToPreferences() {
        ReaderPreferences.fontChoice = fontChoice
        ReaderPreferences.fontSize = fontSize
        ReaderPreferences.theme = theme
    }
}
