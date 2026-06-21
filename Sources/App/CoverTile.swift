import SwiftUI
import UIKit

/// A single library item: cover art (loaded from the container) with title/subtitle.
/// Falls back to a placeholder when there's no cover.
struct CoverTile: View {
    let title: String
    var subtitle: String?
    var coverPath: String?

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
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover))

            Text(title)
                .font(.subheadline)
                .lineLimit(2)

            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var coverImage: UIImage? {
        guard let coverPath,
              let url = try? ContainerPaths.url(forRelativePath: coverPath) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
