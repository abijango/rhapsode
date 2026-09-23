import SwiftUI

/// Offered when a matched book crosses the finish threshold.
///
/// Nothing is written to Hardcover until the user taps Save: marking a book Read is a public
/// feed event, and a false positive (you stopped during the end credits, or scrubbed to the
/// last chapter) posting itself would be worse than one extra tap. Dismissing is a real "no".
struct HardcoverFinishSheet: View {
    let book: Audiobook

    @Environment(HardcoverSyncService.self) private var hardcover
    @Environment(\.dismiss) private var dismiss

    @State private var rating: Double = 0
    @State private var review = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: DS.Spacing.md) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(BrandFont.display(17, .semibold))
                                .lineLimit(3)
                            if let author = book.author {
                                Text(author).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                } header: {
                    Text("Finished")
                }

                Section("Rating") {
                    StarRatingPicker(rating: $rating)
                    if rating > 0 {
                        Button("Clear rating") { rating = 0 }
                            .font(.caption)
                    }
                }

                Section("Review (optional)") {
                    TextField("What did you think?", text: $review, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Mark as Read?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not yet") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            saving = true
                            await hardcover.markFinished(
                                book,
                                rating: rating > 0 ? rating : nil,
                                review: review.isEmpty ? nil : review)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Half-star picker — Hardcover stores `rating` as a numeric supporting halves.
private struct StarRatingPicker: View {
    @Binding var rating: Double

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ForEach(1...5, id: \.self) { index in
                star(index: index)
            }
            Spacer()
            if rating > 0 {
                Text(rating.formatted(.number.precision(.fractionLength(0...1))))
                    .font(ReceiptFont.mono(14, .semibold))
                    .foregroundStyle(DS.Palette.Reclaim.mint)
            }
        }
    }

    private func star(index: Int) -> some View {
        let value = Double(index)
        let symbol: String
        if rating >= value { symbol = "star.fill" }
        else if rating >= value - 0.5 { symbol = "star.leadinghalf.filled" }
        else { symbol = "star" }

        return Image(systemName: symbol)
            .font(.title2)
            .foregroundStyle(DS.Palette.Reclaim.mint)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                // Tapping the star you're already on drops to the half below, so halves are
                // reachable without a drag gesture.
                rating = (rating == value) ? value - 0.5 : value
            }
            .accessibilityLabel("\(index) stars")
    }
}
