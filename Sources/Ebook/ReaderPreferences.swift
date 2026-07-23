import Foundation

/// Global reader appearance defaults, persisted in `UserDefaults` (mirrors `SmartSpeechPreferences`).
enum ReaderPreferences {
    private static let fontKey = "reader.fontChoice"
    private static let fontSizeKey = "reader.fontSize"
    private static let themeKey = "reader.theme"

    static var fontChoice: ReaderFontChoice {
        get {
            let raw = UserDefaults.standard.string(forKey: fontKey)
            if let raw {
                // Built-in or still-registered custom import.
                if ReaderFontCatalog.presets.contains(where: { $0.id == raw })
                    || CustomReaderFontStore.font(preferenceID: raw) != nil {
                    return ReaderFontChoice(rawValue: raw)
                }
            }
            return ReaderFontChoice(rawValue: ReaderFontCatalog.defaultID)
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
