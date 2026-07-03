import SwiftUI

/// Bundled IBM Plex Mono (OFL) — the receipt typeface for Nerd Stats and the per-book player panel.
/// Maps a weight to the specific bundled face (Font.custom doesn't synthesize weights across separate
/// files). Scales with Dynamic Type via `size:`.
enum ReceiptFont {
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black: name = "IBMPlexMono-Bold"
        case .semibold:             name = "IBMPlexMono-SemiBold"
        case .medium:               name = "IBMPlexMono-Medium"
        default:                    name = "IBMPlexMono-Regular"
        }
        return .custom(name, size: size)
    }
}
