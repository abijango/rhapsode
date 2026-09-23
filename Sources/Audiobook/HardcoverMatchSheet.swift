import SwiftData
import SwiftUI

/// Pick which Hardcover *edition* a local audiobook is.
///
/// The design point: a popular title has many editions that look identical in a list — same
/// title, same author, often the same cover. The thing that actually distinguishes the
/// full-cast recording from the paperback is **runtime**, and we can compare that against the
/// file on disk. So each row leads with its runtime and how far it is from your file, rather
/// than hiding that behind an opaque confidence score.
struct HardcoverMatchSheet: View {
    let book: Audiobook

    @Environment(HardcoverSyncService.self) private var hardcover
    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var candidates: [HardcoverCandidate] = []
    @State private var loading = true
    @State private var error: String?
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Searching Hardcover…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Couldn't search Hardcover",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if candidates.isEmpty {
                    ContentUnavailableView("No audiobook editions found",
                                           systemImage: "magnifyingglass",
                                           description: Text("Try a different search term below."))
                } else {
                    list
                }
            }
            .safeAreaInset(edge: .bottom) { searchBar }
            .navigationTitle("Match on Hardcover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        // Dismissing the finish prompt shouldn't strand the book — this is the
                        // way back to marking it Read.
                        if book.hardcoverEditionId != nil {
                            Button("Sync progress now", systemImage: "arrow.up.circle") {
                                // Uses the live player position when this is the book playing,
                                // otherwise the saved one.
                                let progress = player.book?.id == book.id
                                    ? player.bookProgress
                                    : book.shelfFractionComplete
                                Task { await hardcover.pushNow(book, progress: progress) }
                                dismiss()
                            }
                            Button("Mark as Read…", systemImage: "checkmark.circle") {
                                dismiss()
                                hardcover.finishCandidate = book
                            }
                        }
                        Button("Not on Hardcover", systemImage: "nosign") {
                            hardcover.skip(book)
                            dismiss()
                        }
                        if book.hardcoverEditionId != nil {
                            Button("Remove match", systemImage: "trash", role: .destructive) {
                                hardcover.unmatch(book)
                                dismiss()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await search() }
    }

    private var list: some View {
        List {
            Section {
                row(candidates[0], isSuggestion: true)
            } header: {
                Text(candidates[0].isNearExact ? "Best match" : "Closest match")
            } footer: {
                Text(localFileLine)
            }

            if candidates.count > 1 {
                Section("Other editions") {
                    ForEach(candidates.dropFirst()) { row($0, isSuggestion: false) }
                }
            }
        }
    }

    private func row(_ candidate: HardcoverCandidate, isSuggestion: Bool) -> some View {
        Button {
            hardcover.apply(candidate, to: book, state: .manual)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.md) {
                cover(candidate.edition.coverURL, large: isSuggestion)
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.edition.bookTitle)
                        .font(isSuggestion ? BrandFont.display(17, .semibold) : .body)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let narrators = candidate.edition.narratorLine {
                        Text(narrators)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    // The evidence. This is the argument for the match, so it gets the mono
                    // face the rest of the app uses for measurements.
                    Text(candidate.evidence)
                        .font(ReceiptFont.mono(12, .medium))
                        .foregroundStyle(candidate.isNearExact ? DS.Palette.Reclaim.mint : .secondary)
                    if book.hardcoverEditionId == candidate.edition.id {
                        Label("Currently matched", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(DS.Palette.Reclaim.mint)
                    }
                }
                Spacer(minLength: 0)
                if let url = candidate.edition.webURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func cover(_ urlString: String?, large: Bool) -> some View {
        let side: CGFloat = large ? 72 : 48
        return AsyncImage(url: urlString.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            RoundedRectangle(cornerRadius: DS.Radius.cover, style: .continuous)
                .fill(DS.Palette.Reclaim.fill)
        }
        .frame(width: side, height: side * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover, style: .continuous))
    }

    private var searchBar: some View {
        HStack(spacing: DS.Spacing.sm) {
            TextField("Search Hardcover by title or author", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .onSubmit { Task { await search(term: searchText) } }
            Button("Search") { Task { await search(term: searchText) } }
                .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(DS.Spacing.md)
        .background(.bar)
    }

    /// What we're matching against — shown so the runtime comparison above makes sense.
    private var localFileLine: String {
        let runtime = HardcoverCandidate.durationLabel(Int(book.totalDuration.rounded()))
        if let narrator = book.narrator {
            return "Your file: \(runtime) · \(narrator)"
        }
        return "Your file: \(runtime)"
    }

    private func search(term: String? = nil) async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            candidates = try await hardcover.candidates(for: book, query: term)
        } catch {
            self.error = (error as? HardcoverError)?.errorDescription ?? error.localizedDescription
        }
    }
}
