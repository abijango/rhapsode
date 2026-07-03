import SwiftUI
import UIKit

/// A single library item: cover art (loaded from the container) with title/subtitle.
/// Falls back to a placeholder when there's no cover.
struct CoverTile: View {
    let title: String
    var subtitle: String?
    var coverPath: String?
    /// How far through the book the user is (0...1). `nil` hides the progress row
    /// entirely (e.g. media types that don't track it). When provided, the row is
    /// always shown — including "0%" / "Not started" — so the status is visible.
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            RoundedRectangle(cornerRadius: DS.Radius.cover)
                .fill(DS.Palette.coverPlaceholder)
                .aspectRatio(DS.Shelf.coverAspect, contentMode: .fit)
                .overlay {
                    if let image = coverImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "book.closed")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .bottom) { progressStrip }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover))
                // Pointer/hover affordance: system highlight on iPad pointer and Mac Catalyst.
                // No-op on touch (iPhone). Uses .automatic so the system chooses
                // the most appropriate effect for the context.
                .hoverEffect(.automatic)

            Text(title)
                .font(.subheadline)
                .lineLimit(2)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let progress {
                HStack(spacing: DS.Spacing.xs) {
                    LinearProgressBar(fraction: progress, height: 4)
                    Text(Self.progressLabel(progress))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(progress >= 0.995 ? DS.Palette.accent : .secondary)
                        .fixedSize()
                }
            }
        }
        // Tooltip shown on pointer hover (iPad pointer + Mac Catalyst); ignored on touch.
        .help(tooltipText)
    }

    /// A flush accent strip pinned to the bottom of the cover (the "continue"
    /// affordance), shown only once a book has actually been started. Complements
    /// the explicit percentage below the title.
    @ViewBuilder
    private var progressStrip: some View {
        if let progress, progress > 0.001 {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.black.opacity(0.35))
                    Rectangle()
                        .fill(DS.Palette.accent)
                        .frame(width: CGFloat(min(1, max(0, progress))) * geo.size.width)
                }
            }
            .frame(height: 5)
        }
    }

    /// Short status label: "Not started" at 0, "100%" when essentially finished,
    /// otherwise the rounded percentage.
    static func progressLabel(_ p: Double) -> String {
        if p <= 0.001 { return "Not started" }
        if p >= 0.995 { return "100%" }
        return "\(Int((p * 100).rounded()))%"
    }

    /// Tooltip string: "Title — Author" when an author is present, otherwise just the title.
    private var tooltipText: String {
        if let subtitle, !subtitle.isEmpty {
            return "\(title) — \(subtitle)"
        }
        return title
    }

    private var coverImage: UIImage? {
        guard let coverPath,
              let url = try? ContainerPaths.url(forRelativePath: coverPath) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
