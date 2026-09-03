import SwiftUI
import UIKit

// MARK: - Player presentation environment

private struct ExpandAudiobookPlayerKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: ((Audiobook) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the Music-style full-screen player for the given audiobook.
    var expandAudiobookPlayer: ((Audiobook) -> Void)? {
        get { self[ExpandAudiobookPlayerKey.self] }
        set { self[ExpandAudiobookPlayerKey.self] = newValue }
    }
}

// MARK: - Mini player

/// Compact Now Playing chrome: cover, title, play/pause (and skip when there's room).
/// Used as the iOS 26 `tabViewBottomAccessory` and as an iPad/split safe-area inset.
struct NowPlayingAccessory: View {
    var showsSkip: Bool = true
    var coverNamespace: Namespace.ID? = nil
    var onExpand: () -> Void

    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var book: Audiobook? { player.book }
    private var compact: Bool { placement == .inline }
    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        if let book {
            GlassEffectContainer {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Button(action: onExpand) {
                            HStack(spacing: 10) {
                                NowPlayingCoverThumb(
                                    coverPath: book.coverPath,
                                    size: compact ? 28 : 40,
                                    namespace: coverNamespace
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(book.title)
                                        .font(BrandFont.display(compact ? 14 : 15, .semibold))
                                        .foregroundStyle(C.text)
                                        .lineLimit(1)
                                    if !compact, let author = book.author, !author.isEmpty {
                                        Text(author)
                                            .font(BrandFont.display(12, .medium))
                                            .foregroundStyle(C.muted)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityLabel("Now Playing, \(book.title)")
                        .accessibilityHint("Opens the player")

                        Button {
                            player.togglePlayPause()
                        } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(C.mint)
                                .frame(width: 36, height: 36)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                        if showsSkip && !compact {
                            Button {
                                player.skip(30)
                            } label: {
                                Image(systemName: "goforward.30")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(C.mint)
                                    .frame(width: 36, height: 36)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .hoverEffect(.highlight)
                            .accessibilityLabel("Skip forward 30 seconds")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(C.track)
                            Capsule()
                                .fill(C.mint)
                                .frame(width: max(0, geo.size.width * player.bookProgress))
                        }
                    }
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .glassEffect()
        }
    }
}

/// Full-screen Now Playing presented from the accessory (Music-style expand).
struct ExpandedNowPlayingView: View {
    let book: Audiobook
    var coverNamespace: Namespace.ID? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlayerView(audiobook: book, coverNamespace: coverNamespace)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "chevron.down") { dismiss() }
                    }
                }
        }
    }
}

private struct NowPlayingCoverThumb: View {
    let coverPath: String?
    var size: CGFloat = 40
    var namespace: Namespace.ID?

    @State private var image: UIImage?

    private let cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "headphones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .modifier(MatchedCoverEffect(id: "nowPlayingCover", namespace: namespace))
        .task(id: coverPath) {
            guard let coverPath else {
                image = nil
                return
            }
            image = await CoverImageLoader.Cache.shared
                .load(relativePath: coverPath, maxPixelSize: size * 3)?
                .image
        }
    }
}

private struct MatchedCoverEffect: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}
