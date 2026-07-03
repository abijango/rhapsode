import SwiftUI

/// Global light/dark preference, persisted in `@AppStorage("appAppearance")` and applied at the app
/// root via `.preferredColorScheme`. The player and Nerd Stats are deliberately always-dark (Ink &
/// Mint) branded surfaces and use explicit colors, so they stay dark regardless of this setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// The `@AppStorage` key + shared default, so the root and Settings agree.
    static let storageKey = "appAppearance"
}
