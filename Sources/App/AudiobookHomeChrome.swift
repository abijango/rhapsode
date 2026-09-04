import SwiftUI
import UIKit

// MARK: - Collection circles

/// Overcast-style circular collection filters for the audiobooks home.
struct CollectionCircleBar: View {
    let collections: [LibraryCollection]
    @Binding var selectedID: UUID?
    let onManage: () -> Void

    private static let palette: [Color] = [
        .blue, .orange, .green, .purple, .pink, .teal, .indigo, .mint,
    ]

    static func color(for id: UUID) -> Color {
        var hasher = Hasher()
        hasher.combine(id)
        let index = Int(hasher.finalize().magnitude % UInt(palette.count))
        return palette[index]
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.lg) {
                circleButton(
                    label: "All",
                    isSelected: selectedID == nil,
                    fill: Color(.tertiarySystemFill)
                ) {
                    Image(systemName: "list.bullet")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                } action: {
                    selectedID = nil
                }

                ForEach(collections) { collection in
                    let tint = Self.color(for: collection.id)
                    circleButton(
                        label: collection.name,
                        isSelected: selectedID == collection.id,
                        fill: tint.opacity(selectedID == collection.id ? 1 : 0.85)
                    ) {
                        collectionGlyph(collection.name, tint: .white)
                    } action: {
                        selectedID = collection.id
                    }
                }

                circleButton(
                    label: "Manage",
                    isSelected: false,
                    fill: Color(.tertiarySystemFill)
                ) {
                    Image(systemName: "gearshape.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                } action: {
                    onManage()
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
        }
    }

    @ViewBuilder
    private func circleButton<Glyph: View>(
        label: String,
        isSelected: Bool,
        fill: Color,
        @ViewBuilder glyph: () -> Glyph,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.xs) {
                ZStack {
                    Circle()
                        .fill(fill)
                        .frame(width: 52, height: 52)
                    glyph()
                }
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(DS.Palette.accent, lineWidth: 2.5)
                            .frame(width: 58, height: 58)
                    }
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 64)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func collectionGlyph(_ name: String, tint: Color) -> some View {
        if let letter = name.first(where: { $0.isLetter }) {
            Text(String(letter).uppercased())
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
        } else {
            Image(systemName: "folder.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Continue card

struct ContinueCard: View {
    enum Status: String {
        case playing = "PLAYING"
        case paused = "PAUSED"
    }

    let title: String
    var coverPath: String?
    let status: Status

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            cover
            Text(status.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(status == .playing ? DS.Palette.accent : .secondary)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: coverPath) {
            image = nil
            guard let coverPath else { return }
            let maxPixels = 180 * displayScale * 2
            if let loaded = await CoverImageLoader.Cache.shared.load(
                relativePath: coverPath,
                maxPixelSize: maxPixels
            ) {
                image = loaded.image
            }
        }
    }

    private var cover: some View {
        RoundedRectangle(cornerRadius: DS.Radius.cover)
            .fill(DS.Palette.coverPlaceholder)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "headphones")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover))
    }
}

// MARK: - Library list row

struct LibraryListRow: View {
    enum Appearance: Sendable {
        case local
        case remote
    }

    let title: String
    var subtitle: String?
    var coverPath: String?
    var appearance: Appearance = .local

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    private var isRemote: Bool { appearance == .remote }

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(isRemote ? .secondary : .primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, DS.Spacing.sm)
        .task(id: coverPath) {
            image = nil
            guard let coverPath else { return }
            let maxPixels = Self.coverSize * displayScale * 2
            if let loaded = await CoverImageLoader.Cache.shared.load(
                relativePath: coverPath,
                maxPixelSize: maxPixels
            ) {
                image = loaded.image
            }
        }
    }

    private static let coverSize: CGFloat = 56

    private var cover: some View {
        RoundedRectangle(cornerRadius: DS.Radius.cover)
            .fill(DS.Palette.coverPlaceholder)
            .frame(width: Self.coverSize, height: Self.coverSize)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.coverSize, height: Self.coverSize)
                } else {
                    Image(systemName: isRemote ? "icloud.and.arrow.down" : "headphones")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover))
            .opacity(isRemote ? 0.55 : 1)
            .saturation(isRemote ? 0.4 : 1)
    }
}
