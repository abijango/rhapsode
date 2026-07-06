import SwiftData
import SwiftUI
import UIKit

/// "Nerd Stats" — a top-level destination (between E-books and Settings). The "Reclaimed" view:
/// a celebratory hero (total silence reclaimed) over an artwork-led per-book list, each row showing
/// listened time, silence saved, and % saved. Always-dark Ink & Mint branded surface; Hanken Grotesk
/// display + IBM Plex Mono data. Future home for e-book reading stats too.
///
/// "Listened"/"played" = trimmed CONTENT seconds actually heard (rate-independent); "saved" = silence
/// collapsed while trimming was active. Lifetime totals live in `SmartSpeechStats` (UserDefaults), polled
/// ~1×/s so the hero ticks up live; the per-book rows come from SwiftData.
struct NerdStatsView: View {
    @Query(sort: \Audiobook.title) private var books: [Audiobook]

    @State private var totalPlayed: TimeInterval = 0
    @State private var totalSaved: TimeInterval = 0

    /// Books that have reclaimed any silence, most-reclaimed first (drives the "Most reclaimed" list).
    private var reclaimedBooks: [Audiobook] {
        books
            .filter { ($0.smartSpeechSavedSeconds ?? 0) > 0 }
            .sorted { ($0.smartSpeechSavedSeconds ?? 0) > ($1.smartSpeechSavedSeconds ?? 0) }
    }
    private var maxSaved: Double { reclaimedBooks.first?.smartSpeechSavedSeconds ?? 1 }
    private var overallPct: Int {
        totalPlayed > 0 ? Int((totalSaved / totalPlayed * 100).rounded()) : 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if reclaimedBooks.isEmpty && totalSaved <= 0 { empty } else { content }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
            }
            .background(background)
            .navigationTitle("Nerd Stats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DS.Palette.Reclaim.bg1, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task {
                while !Task.isCancelled {
                    totalPlayed = SmartSpeechStats.totalPlayedSeconds
                    totalSaved = SmartSpeechStats.totalSavedSeconds
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private var background: some View {
        LinearGradient(colors: [DS.Palette.Reclaim.bg1, DS.Palette.Reclaim.bg2],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // MARK: Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            hero
            Text("MOST RECLAIMED")
                .font(ReceiptFont.mono(11)).kerning(2)
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .padding(.top, DS.Spacing.xl)
                .padding(.bottom, DS.Spacing.sm)
            if reclaimedBooks.isEmpty {
                Text("No books in your library have recorded savings yet — the lifetime total above may include books no longer here. Per-book rows appear as you listen.")
                    .font(ReceiptFont.mono(12))
                    .foregroundStyle(DS.Palette.Reclaim.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(reclaimedBooks) { book in row(book) }
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(reclaimedBooks.isEmpty ? "LIFETIME"
                 : "LIFETIME · \(reclaimedBooks.count) BOOK\(reclaimedBooks.count == 1 ? "" : "S")")
                .font(ReceiptFont.mono(11)).kerning(2)
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .padding(.bottom, DS.Spacing.md)
            Text("You’ve reclaimed")
                .font(BrandFont.display(17, .medium))
                .foregroundStyle(DS.Palette.Reclaim.muted)
            Text(Self.hms(totalSaved))
                .font(BrandFont.display(58, .heavy))
                .foregroundStyle(DS.Palette.Reclaim.mintBright)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, 2)
            (Text("of silence from ")
                + Text(Self.hoursListened(totalPlayed)).foregroundColor(DS.Palette.Reclaim.text)
                + Text(" listened · ")
                + Text("\(overallPct)% back").foregroundColor(DS.Palette.Reclaim.text))
                .font(ReceiptFont.mono(12))
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .padding(.top, DS.Spacing.sm)
        }
    }

    private func row(_ book: Audiobook) -> some View {
        let played = book.listenedSeconds ?? 0
        let saved = book.smartSpeechSavedSeconds ?? 0
        let pct = played > 0 ? Int((saved / played * 100).rounded()) : 0
        return HStack(alignment: .center, spacing: 13) {
            coverThumb(book)
            VStack(alignment: .leading, spacing: 8) {
                Text(shortTitle(book.title))
                    .font(BrandFont.display(16, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.text)
                    .lineLimit(1)
                miniBar(fraction: maxSaved > 0 ? saved / maxSaved : 0)
                Text("\(Self.hoursListened(played)) listened")
                    .font(ReceiptFont.mono(11))
                    .foregroundStyle(DS.Palette.Reclaim.muted)
            }
            VStack(alignment: .trailing, spacing: 6) {
                Text(Self.hms(saved))
                    .font(ReceiptFont.mono(15, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.mintBright)
                Text("\(pct)% saved")
                    .font(ReceiptFont.mono(11))
                    .foregroundStyle(DS.Palette.Reclaim.muted)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.Reclaim.hairline).frame(height: 1)
        }
    }

    private func miniBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.Reclaim.track)
                Capsule().fill(DS.Palette.Reclaim.mintBright)
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 6)
    }

    @ViewBuilder
    private func coverThumb(_ book: Audiobook) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        if let rel = book.coverPath,
           let url = try? ContainerPaths.url(forRelativePath: rel),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
                .frame(width: 44, height: 44).clipShape(shape)
        } else {
            shape.fill(DS.Palette.Reclaim.surface)
                .frame(width: 44, height: 44)
                .overlay(Image(systemName: "headphones")
                    .font(.system(size: 16)).foregroundStyle(DS.Palette.Reclaim.muted))
        }
    }

    private var empty: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("LIFETIME").font(ReceiptFont.mono(11)).kerning(2)
                .foregroundStyle(DS.Palette.Reclaim.muted)
            Text("Nothing reclaimed yet")
                .font(BrandFont.display(24, .bold))
                .foregroundStyle(DS.Palette.Reclaim.text)
            Text("Play an audiobook with trimming on and\nyour reclaimed time shows up here.")
                .font(ReceiptFont.mono(12))
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    static let saved = DS.Palette.Reclaim.mintBright

    // MARK: Formatting

    /// Full H·M·S, always down to seconds (small reclaims are common): "26h 12m 30s", "54m 30s", "45s".
    static func hms(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Coarse listened total for context lines, e.g. "214h", "9h", "42m".
    static func hoursListened(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        let h = t / 3600, m = (t % 3600) / 60
        if h > 0 { return "\(h)h" }
        return "\(m)m"
    }

    /// Compact receipt duration: "3h12m", "52m", "45s". Kept for the per-book player panel.
    static func compact(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds.rounded()))
        if t < 60 { return "\(t)s" }
        let m = t / 60, h = m / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    static func dur(_ seconds: TimeInterval) -> String { compact(seconds) }
    static func hm(_ seconds: TimeInterval) -> String { compact(seconds) }

    /// Trim a common trailing parenthetical (e.g. "(Full-Cast Edition)") so titles stay tidy.
    private func shortTitle(_ title: String) -> String {
        if let range = title.range(of: " (") { return String(title[..<range.lowerBound]) }
        return title
    }
}
