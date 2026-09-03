import SwiftUI
import UIKit

/// A single library item: cover art (loaded from the container) with title/subtitle.
/// Falls back to a placeholder when there's no cover.
///
/// The cover **frame** matches the art’s aspect ratio (square audiobooks, portrait
/// e-books, etc.) so there is no grey letterbox above/below the image.
struct CoverTile: View {
    /// On-device library cover vs remote-only (server catalogue) greyed tile.
    enum Appearance: Sendable {
        case local
        case remote
    }

    let title: String
    var subtitle: String?
    var coverPath: String?
    /// How far through the book the user is (0...1). `nil` hides the progress row
    /// entirely (e.g. media types that don't track it). When provided, the row is
    /// always shown — including "0%" / "Not started" — so the status is visible.
    var progress: Double?
    var appearance: Appearance = .local
    /// Drives the empty-state aspect (square vs portrait) when art is not loaded yet.
    var kind: FolderKind = .books

    /// On iPad / Mac (regular size class) covers are large, so scale the title, author, and
    /// especially the progress bar + % up to stay readable on a big, high-resolution screen.
    /// iPhone (compact) keeps the denser layout.
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedAspect: CGFloat?

    private var isRegular: Bool { hSize == .regular }
    private var isRemote: Bool { appearance == .remote }

    /// Width ÷ height of the cover box: cached from the loader, kind default before art arrives.
    private var boxAspect: CGFloat {
        loadedAspect ?? DS.Shelf.placeholderCoverAspect(for: kind)
    }

    /// Downsample target — large enough for retina shelf tiles without decoding full art.
    private var maxCoverPixels: CGFloat {
        let width = isRegular ? DS.Shelf.coverWidthRegular : 180
        return width * displayScale * 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isRegular ? DS.Spacing.md : DS.Spacing.xs) {
            // Frame aspect follows the art so square Audible jackets and tall e-book
            // covers both sit flush (no wasted bands top/bottom).
            RoundedRectangle(cornerRadius: DS.Radius.cover)
                .fill(DS.Palette.coverPlaceholder)
                .aspectRatio(boxAspect, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            // Box matches art aspect → fill ≈ fit, flush to edges.
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Image(systemName: isRemote ? "icloud.and.arrow.down" : placeholderIcon)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isRemote {
                        Image(systemName: "icloud")
                            .font(.caption.weight(.semibold))
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) { progressStrip }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover))
                // Remote catalogue tiles: dimmed art so on-device vs not-downloaded is clear.
                .opacity(isRemote ? 0.55 : 1)
                .saturation(isRemote ? 0.4 : 1)
                // Pointer/hover affordance: system highlight on iPad pointer and Mac Catalyst.
                // No-op on touch (iPhone). Uses .automatic so the system chooses
                // the most appropriate effect for the context.
                .hoverEffect(.automatic)

            Text(title)
                .font(isRegular ? .headline : .subheadline)
                .foregroundStyle(isRemote ? .secondary : .primary)
                .lineLimit(2)

            if let subtitle {
                Text(subtitle)
                    .font(isRegular ? .subheadline : .caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let progress, !isRemote {
                HStack(spacing: isRegular ? DS.Spacing.sm : DS.Spacing.xs) {
                    LinearProgressBar(fraction: progress, height: isRegular ? 8 : 4, animated: false)
                    Text(Self.progressLabel(progress))
                        .font((isRegular ? Font.headline : Font.caption2).monospacedDigit())
                        .foregroundStyle(progress >= 0.995 ? DS.Palette.accent : .secondary)
                        .fixedSize()
                }
            }
        }
        // Tooltip shown on pointer hover (iPad pointer + Mac Catalyst); ignored on touch.
        .help(tooltipText)
        .task(id: coverPath) {
            image = nil
            loadedAspect = nil
            guard let coverPath else { return }
            if let loaded = await CoverImageLoader.Cache.shared.load(
                relativePath: coverPath,
                maxPixelSize: maxCoverPixels
            ) {
                image = loaded.image
                loadedAspect = loaded.aspectRatio
            }
        }
    }

    private var placeholderIcon: String {
        kind == .audiobooks ? "headphones" : "book.closed"
    }

    /// A flush accent strip pinned to the bottom of the cover (the "continue"
    /// affordance), shown only once a book has actually been started. Complements
    /// the explicit percentage below the title.
    @ViewBuilder
    private var progressStrip: some View {
        if let progress, progress > 0.001 {
            LinearProgressBar(
                fraction: progress,
                height: isRegular ? 8 : 5,
                track: Color.black.opacity(0.35),
                animated: false
            )
            .padding(.horizontal, 6)
            .padding(.bottom, 6)
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

}
