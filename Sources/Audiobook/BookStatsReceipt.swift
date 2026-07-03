import SwiftUI

/// Single-book "receipt" shown behind the cover in the player (swipe / toggle). Matches the Nerd
/// Stats page receipt (torn edges, dashed rules, SF Mono). Reads the model + player live, so it ticks
/// up in real time as playback accrues.
struct BookStatsReceipt: View {
    let book: Audiobook
    let player: AudiobookPlayer

    var body: some View {
        let played = book.listenedSeconds ?? 0
        let saved = book.cadenceSavedSeconds ?? 0
        let pct = played > 0 ? Int((saved / played * 100).rounded()) : 0
        return VStack(spacing: 0) {
            VStack(spacing: 3) {
                Text("RHAPSODE")
                    .font(ReceiptFont.mono(15, .bold)).kerning(4)
                Text("NOW PLAYING · LIVE")
                    .font(ReceiptFont.mono(10)).kerning(1)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            DashedRule().padding(.vertical, 12)

            line("Listened", NerdStatsView.compact(played))
            line("Saved", "−\(NerdStatsView.compact(saved))", color: NerdStatsView.saved)
            line("% saved", "\(pct)%")
            line("Speed", String(format: "%g×", player.rate))
            line("Trimming", player.isTrimming ? "ON" : "OFF",
                 color: player.isTrimming ? NerdStatsView.saved : .secondary)

            DashedRule().padding(.vertical, 12)

            HStack(alignment: .firstTextBaseline) {
                Text("★ SAVED")
                    .font(ReceiptFont.mono(12, .medium)).kerning(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(NerdStatsView.compact(saved))
                    .font(ReceiptFont.mono(19, .bold))
                    .foregroundStyle(NerdStatsView.saved)
            }
        }
        .padding(24)
        .background(ReceiptShape().fill(Color(.systemBackground))
            .shadow(color: .black.opacity(0.10), radius: 12, y: 6))
    }

    private func line(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(ReceiptFont.mono(14))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(ReceiptFont.mono(15, .medium))
                .foregroundStyle(color)
        }
        .padding(.vertical, 3)
    }
}

#if DEBUG
/// DEBUG-only harness so the per-book receipt can be screenshotted in isolation (launch arg
/// `-previewbookstats`), since reaching it in-app needs deep navigation.
struct BookStatsPreviewHarness: View {
    var body: some View {
        let book = Audiobook(title: "Harry Potter and the Goblet of Fire", sourcePath: "preview")
        book.listenedSeconds = 11_520
        book.cadenceSavedSeconds = 1_440
        let player = AudiobookPlayer()
        player.rate = 1.5
        return ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()
            BookStatsReceipt(book: book, player: player)
                .frame(maxWidth: 340)
                .padding()
        }
    }
}
#endif
