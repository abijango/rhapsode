import SwiftUI
import UIKit

/// Compact Now Playing chrome: cover, title, play/pause (and skip when there's room).
/// Used as the iOS 26 `tabViewBottomAccessory` and as an iPad/split safe-area inset.
struct NowPlayingAccessory: View {
    var showsSkip: Bool = true
    var usesMaterialBackground: Bool = false
    var onExpand: () -> Void

    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var book: Audiobook? { player.book }
    private var compact: Bool { placement == .inline }

    var body: some View {
        if let book {
            HStack(spacing: 10) {
                Button(action: onExpand) {
                    HStack(spacing: 10) {
                        NowPlayingCoverThumb(coverPath: book.coverPath, size: compact ? 28 : 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !compact, let author = book.author, !author.isEmpty {
                                Text(author)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Now Playing, \(book.title)")
                .accessibilityHint("Opens the player")

                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                if showsSkip && !compact {
                    Button {
                        player.skip(30)
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.body.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip forward 30 seconds")
                }
            }
            .padding(.horizontal, usesMaterialBackground ? 12 : 4)
            .padding(.vertical, usesMaterialBackground ? 8 : 0)
            .background {
                if usesMaterialBackground {
                    Rectangle().fill(.bar)
                }
            }
        }
    }
}

/// Full-screen Now Playing presented from the accessory (Music-style expand).
struct ExpandedNowPlayingView: View {
    let book: Audiobook
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PlayerView(audiobook: book)
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

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(.secondarySystemFill))
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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
