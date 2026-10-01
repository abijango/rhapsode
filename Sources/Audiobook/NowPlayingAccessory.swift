import SwiftUI
import UIKit

// MARK: - Player presentation environment

private struct ExpandAudiobookPlayerKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: ((Audiobook) -> Void)? = nil
}

extension EnvironmentValues {
    /// Opens the rich player for the given audiobook.
    /// Compact width uses a full-screen cover; regular width uses the split detail column.
    var expandAudiobookPlayer: ((Audiobook) -> Void)? {
        get { self[ExpandAudiobookPlayerKey.self] }
        set { self[ExpandAudiobookPlayerKey.self] = newValue }
    }
}

private struct OpenSettingsKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openSettings: (() -> Void)? {
        get { self[OpenSettingsKey.self] }
        set { self[OpenSettingsKey.self] = newValue }
    }
}

private struct OpenDownloadsKey: EnvironmentKey {
    nonisolated(unsafe) static var defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var openDownloads: (() -> Void)? {
        get { self[OpenDownloadsKey.self] }
        set { self[OpenDownloadsKey.self] = newValue }
    }
}

// MARK: - Mini player

/// Compact Now Playing chrome: cover, title, and play/pause, with a progress track when expanded.
/// Shown in a bottom safe-area inset. The tab bar's bottom accessory is a short capsule and
/// clips this bar, so the phone path does not use it.
struct NowPlayingAccessory: View {
    var coverNamespace: Namespace.ID? = nil
    var onExpand: () -> Void

    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var book: Audiobook? { player.book }
    private var compact: Bool { placement == .inline }
    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    /// Inline sits in the collapsed tab bar. Expanded is a rounded rect tall enough for the
    /// cover, the play button, and a track underneath. A capsule clips the cover: its end
    /// caps cut the top of the art.
    private var barHeight: CGFloat { compact ? 40 : 100 }
    private var coverSide: CGFloat { compact ? 28 : 52 }
    private var playSide: CGFloat { compact ? 28 : 44 }
    private var progressHeight: CGFloat { 8 }

    var body: some View {
        if let book {
            bar(for: book)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: barHeight, alignment: .center)
                .modifier(AccessoryGlass(compact: compact))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bar(for book: Audiobook) -> some View {
        VStack(spacing: compact ? 0 : 12) {
            controlRow(for: book)
            if !compact {
                listenProgress
            }
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 0 : 14)
    }

    private func controlRow(for book: Audiobook) -> some View {
        HStack(spacing: 12) {
            Button(action: onExpand) {
                HStack(spacing: 12) {
                    NowPlayingCoverThumb(
                        coverPath: book.coverPath,
                        size: coverSide,
                        namespace: coverNamespace
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AUDIOBOOK")
                            .font(ReceiptFont.mono(compact ? 9 : 10))
                            .kerning(1)
                            .foregroundStyle(C.muted)
                            .lineLimit(1)
                        Text(book.title)
                            .font(BrandFont.display(compact ? 14 : 16, .semibold))
                            .foregroundStyle(C.text)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Now Playing, \(book.title)")
            .accessibilityHint("Opens the player")

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(C.mint)
                        .frame(width: playSide, height: playSide)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 12 : 18, weight: .bold))
                        .foregroundStyle(C.onMint)
                }
                .frame(width: compact ? 32 : 48, height: compact ? 32 : 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
    }

    /// Own row under the controls. The filled track takes the width; the geometry reader
    /// only paints the played portion and does not affect the row's layout.
    private var listenProgress: some View {
        Capsule()
            .fill(C.track)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    Capsule()
                        .fill(C.mint)
                        .frame(width: max(0, geo.size.width * player.bookProgress))
                }
            }
            .frame(height: progressHeight)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Capsule when the accessory is collapsed into the tab bar. Expanded uses a rounded
/// rectangle so the cover and play button sit clear of the corners.
private struct AccessoryGlass: ViewModifier {
    var compact: Bool

    func body(content: Content) -> some View {
        if compact {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: 28))
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
            PlayerView(audiobook: book, coverNamespace: coverNamespace, onDismiss: { dismiss() })
        }
    }
}

struct SplitNowPlayingView: View {
    let book: Audiobook
    var coverNamespace: Namespace.ID? = nil
    var onClose: () -> Void

    var body: some View {
        NavigationStack {
            PlayerView(audiobook: book, coverNamespace: coverNamespace)
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Library", systemImage: "chevron.backward", action: onClose)
                            .hoverEffect(.highlight)
                    }
                }
        }
        .background(DS.Palette.Reclaim.bg1.ignoresSafeArea())
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
