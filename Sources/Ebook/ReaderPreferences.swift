import Foundation

/// Global reader appearance defaults, persisted in `UserDefaults` (mirrors `SmartSpeechPreferences`).
enum ReaderPreferences {
    private static let fontKey = "reader.fontChoice"
    private static let fontSizeKey = "reader.fontSize"
    private static let themeKey = "reader.theme"

    static var fontChoice: ReaderFontChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: fontKey),
                  let choice = ReaderFontChoice(rawValue: raw) else { return .literata }
            return choice
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: fontKey) }
    }

    static var fontSize: Double {
        get {
            let v = UserDefaults.standard.double(forKey: fontSizeKey)
            return v > 0 ? v : 1.0
        }
        set { UserDefaults.standard.set(newValue, forKey: fontSizeKey) }
    }

    static var theme: ReaderSettings.ReaderTheme {
        get {
            guard let raw = UserDefaults.standard.string(forKey: themeKey),
                  let theme = ReaderSettings.ReaderTheme(rawValue: raw) else { return .light }
            return theme
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: themeKey) }
    }
}