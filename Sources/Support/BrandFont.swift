import SwiftUI

/// Bundled Hanken Grotesk (OFL) — the display face for the "Reclaimed" player and Nerd Stats
/// (titles + big stat numbers). Pairs with `ReceiptFont` (IBM Plex Mono) for data. Maps a weight to
/// the specific bundled static face (Font.custom doesn't synthesize weights across separate files).
/// Scales with Dynamic Type via `size:`.
enum BrandFont {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        let name: String
        switch weight {
        case .black, .heavy: name = "HankenGrotesk-ExtraBold"
        case .bold:          name = "HankenGrotesk-Bold"
        case .semibold:      name = "HankenGrotesk-SemiBold"
        case .medium:        name = "HankenGrotesk-Medium"
        default:             name = "HankenGrotesk-Regular"
        }
        return .custom(name, size: size)
    }
}
