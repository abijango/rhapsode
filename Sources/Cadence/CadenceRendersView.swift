import SwiftData
import SwiftUI

/// Dedicated screen (linked from Settings) listing every audiobook's Cadence render status and how
/// long its render took. Live-updates the in-flight render by polling the coordinator's snapshot
/// while on screen.
struct CadenceRendersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Audiobook.title) private var books: [Audiobook]
    @State private var snapshot = CadenceRenderCoordinator.RenderSnapshot(activeProgress: [:], queued: [])

    var body: some View {
        Group {
            if books.isEmpty {
                ContentUnavailableView(
                    "No Audiobooks",
                    systemImage: "headphones",
                    description: Text("Audiobooks render here when \(CadenceBranding.featureName) is on for them.")
                )
            } else {
                List(books) { book in
                    CadenceRenderRow(
                        book: book,
                        progress: snapshot.activeProgress[book.id],
                        queued: snapshot.queued.contains(book.id),
                        summary: Audiobook.renderSummary(forBookID: book.id, context: modelContext))
                }
            }
        }
        .navigationTitle("\(CadenceBranding.featureName) Renders")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Poll the coordinator while on screen so in-flight render progress updates live.
            while !Task.isCancelled {
                snapshot = await CadenceRenderCoordinator.shared.snapshot()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

private struct CadenceRenderRow: View {
    let book: Audiobook
    let progress: Double?
    let queued: Bool
    let summary: (savedSeconds: TimeInterval, renderSeconds: TimeInterval, hasRendition: Bool)

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Text(book.title).lineLimit(1)
                Spacer()
                Text(statusText)
                    .font(.headline)
                    .foregroundStyle(statusColor)
            }
            if let progress {
                LinearProgressBar(fraction: progress, height: 12)
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private var isOff: Bool {
        if case .off = book.resolvedCadence { return true }
        return false
    }

    private var statusText: String {
        if book.cadenceUnavailable == true { return "Unavailable" }
        if isOff { return "Off" }
        if let progress { return "Trimming \(Int((progress * 100).rounded()))%" }
        if queued { return "Queued" }
        if summary.hasRendition {
            return "Done · \(Self.compact(summary.renderSeconds)) · −\(Self.compact(summary.savedSeconds))"
        }
        return "Original"   // resolves on, but not rendered yet
    }

    private var statusColor: Color {
        if book.cadenceUnavailable == true || isOff { return .secondary }
        if progress != nil || queued { return DS.Palette.accent }
        if summary.hasRendition { return .green }
        return .secondary
    }

    /// Minute-granular compact duration: "1h 3m", "47m", "45s".
    static func compact(_ seconds: TimeInterval) -> String {
        guard seconds >= 1 else { return "0s" }
        let total = Int(seconds), h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }
}
