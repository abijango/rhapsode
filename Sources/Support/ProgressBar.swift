import SwiftUI

/// A rounded capsule progress bar used consistently across the app (audiobook
/// player book-progress, library shelf). `fraction` is clamped to 0...1 and is
/// NaN-safe — a non-finite value renders as an empty track.
///
/// One component, one meaning ("how far through"), one accent color — so book
/// progress reads identically wherever it appears.
struct LinearProgressBar: View {
    let fraction: Double
    var height: CGFloat = 6
    var fill: Color = DS.Palette.accent
    var track: Color = Color(.tertiarySystemFill)

    private var clamped: CGFloat {
        guard fraction.isFinite else { return 0 }
        return CGFloat(min(1, max(0, fraction)))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(fill)
                    .frame(width: clamped * geo.size.width)
                    .animation(.easeInOut(duration: 0.25), value: clamped)
            }
        }
        .frame(height: height)
    }
}
