import SwiftData
import SwiftUI
import UIKit

/// "Nerd Stats" — a top-level destination (between E-books and Settings). Audiobook "Reclaimed"
/// stats (silence trimmed) plus an e-book "Reading" section (foreground time + progress). Ink & Mint
/// for audiobooks; warm sepia accent for e-books. Hanken Grotesk display + IBM Plex Mono data.
///
/// "Listened"/"played" = trimmed CONTENT seconds actually heard (rate-independent); "saved" = silence
/// collapsed while trimming was active. Lifetime totals live in `SmartSpeechStats` (UserDefaults), polled
/// ~1×/s so the hero ticks up live; the per-book rows come from SwiftData.
struct NerdStatsView: View {
    @Query(sort: \Audiobook.title) private var books: [Audiobook]
    @Query(sort: \Book.title) private var ebooks: [Book]
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.scenePhase) private var scenePhase

    @State private var totalPlayed: TimeInterval = 0
    @State private var totalSaved: TimeInterval = 0
    @State private var showRecalcConfirm = false
    @State private var noticeText: String?

    /// Books that have reclaimed any silence, most-reclaimed first (drives the "Most reclaimed" list).
    private var reclaimedBooks: [Audiobook] {
        books
            .filter { ($0.smartSpeechSavedSeconds ?? 0) > 0 }
            .sorted { ($0.smartSpeechSavedSeconds ?? 0) > ($1.smartSpeechSavedSeconds ?? 0) }
    }
    /// E-books with any recorded reading time, most-read first.
    private var readEbooks: [Book] {
        ebooks
            .filter { ($0.readingSeconds ?? 0) > 0 }
            .sorted { ($0.readingSeconds ?? 0) > ($1.readingSeconds ?? 0) }
    }
    private var totalReading: TimeInterval {
        ebooks.reduce(0) { $0 + ($1.readingSeconds ?? 0) }
    }
    private var finishedCount: Int { ebooks.filter { $0.finishedAt != nil }.count }
    private var inProgressCount: Int {
        ebooks.filter { ($0.readingSeconds ?? 0) > 0 && $0.finishedAt == nil }.count
    }
    private var hasAudiobookStats: Bool { !reclaimedBooks.isEmpty || totalSaved > 0 }
    private var hasEbookStats: Bool { totalReading > 0 }
    private var maxSaved: Double { reclaimedBooks.first?.smartSpeechSavedSeconds ?? 1 }
    private var overallPct: Int {
        totalPlayed > 0 ? Int((totalSaved / totalPlayed * 100).rounded()) : 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if !hasAudiobookStats && !hasEbookStats { empty } else { content }
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { backUpNow() } label: {
                            Label("Back up stats now", systemImage: "icloud.and.arrow.up")
                        }
                        Button { showRecalcConfirm = true } label: {
                            Label("Recalculate from library", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").tint(DS.Palette.Reclaim.mint)
                    }
                }
            }
            .confirmationDialog("Recalculate lifetime stats?", isPresented: $showRecalcConfirm, titleVisibility: .visible) {
                Button("Recalculate", role: .destructive) { recalcStats() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sets the lifetime reclaimed/listened totals to the sum across your current books, then backs them up. Use this if the total looks wrong.")
            }
            .alert("Stats", isPresented: Binding(get: { noticeText != nil }, set: { if !$0 { noticeText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(noticeText ?? "") }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    totalPlayed = SmartSpeechStats.totalPlayedSeconds
                    totalSaved = SmartSpeechStats.totalSavedSeconds
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// Rebuild the lifetime totals from the per-book values, then back them up. Fixes a lifetime
    /// counter that has drifted from the library.
    private func recalcStats() {
        let saved = books.reduce(0.0) { $0 + ($1.smartSpeechSavedSeconds ?? 0) }
        let played = books.reduce(0.0) { $0 + ($1.listenedSeconds ?? 0) }
        SmartSpeechStats.overwrite(savedSeconds: saved, playedSeconds: played)
        totalSaved = saved; totalPlayed = played
        Task { await sync.pushSmartSpeechStats() }
        noticeText = "Recalculated from your library and backed up."
    }

    /// Force a backup of the lifetime stats to the Dropbox app folder (they also back up
    /// automatically, but this makes it explicit so they can't be lost).
    private func backUpNow() {
        Task {
            await sync.pushSmartSpeechStats()
            noticeText = "Your stats are backed up to Dropbox."
        }
    }

    private var background: some View {
        LinearGradient(colors: [DS.Palette.Reclaim.bg1, DS.Palette.Reclaim.bg2],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // MARK: Content

    private var content: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if hasAudiobookStats {
                audiobookHero
                Text("AUDIOBOOKS · SMARTSPEECH")
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
                    ForEach(reclaimedBooks) { book in audiobookRow(book) }
                }
            }
            if hasEbookStats {
                ebookHero
                    .padding(.top, hasAudiobookStats ? DS.Spacing.xl : 0)
                Text("E-BOOKS · READING")
                    .font(ReceiptFont.mono(11)).kerning(2)
                    .foregroundStyle(DS.Palette.Reclaim.muted)
                    .padding(.top, DS.Spacing.xl)
                    .padding(.bottom, DS.Spacing.sm)
                if readEbooks.isEmpty {
                    Text("No e-books in your library have recorded reading time yet.")
                        .font(ReceiptFont.mono(12))
                        .foregroundStyle(DS.Palette.Reclaim.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(readEbooks) { book in ebookRow(book) }
                }
            }
        }
    }

    private var audiobookHero: some View {
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

    private var ebookHero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("LIFETIME · \(readEbooks.count) BOOK\(readEbooks.count == 1 ? "" : "S")")
                .font(ReceiptFont.mono(11)).kerning(2)
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .padding(.bottom, DS.Spacing.md)
            Text("You've read for")
                .font(BrandFont.display(17, .medium))
                .foregroundStyle(DS.Palette.Reclaim.muted)
            Text(Self.hms(totalReading))
                .font(BrandFont.display(58, .heavy))
                .foregroundStyle(Self.ebookAccent)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .padding(.top, 2)
            (Text("\(finishedCount) finished")
                + Text(" · ")
                + Text("\(inProgressCount) in progress").foregroundColor(DS.Palette.Reclaim.text))
                .font(ReceiptFont.mono(12))
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .padding(.top, DS.Spacing.sm)
        }
    }

    private func audiobookRow(_ book: Audiobook) -> some View {
        let played = book.listenedSeconds ?? 0
        let saved = book.smartSpeechSavedSeconds ?? 0
        let pct = played > 0 ? Int((saved / played * 100).rounded()) : 0
        return HStack(alignment: .center, spacing: 13) {
            NerdStatsCoverThumb(coverPath: book.coverPath, placeholderIcon: "headphones")
            VStack(alignment: .leading, spacing: 8) {
                Text(shortTitle(book.title))
                    .font(BrandFont.display(16, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.text)
                    .lineLimit(1)
                miniBar(fraction: maxSaved > 0 ? saved / maxSaved : 0, fill: DS.Palette.Reclaim.mintBright)
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

    private func ebookRow(_ book: Book) -> some View {
        let read = book.readingSeconds ?? 0
        let progress = book.fractionComplete
        let pct = Int((progress * 100).rounded())
        return HStack(alignment: .center, spacing: 13) {
            NerdStatsCoverThumb(coverPath: book.coverPath, placeholderIcon: "book.closed")
            VStack(alignment: .leading, spacing: 8) {
                Text(shortTitle(book.title))
                    .font(BrandFont.display(16, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.text)
                    .lineLimit(1)
                miniBar(fraction: progress, fill: DS.Palette.Reclaim.mintBright)
                Text(book.finishedAt != nil ? "Finished" : "\(pct)% through")
                    .font(ReceiptFont.mono(11))
                    .foregroundStyle(DS.Palette.Reclaim.muted)
            }
            VStack(alignment: .trailing, spacing: 6) {
                Text(Self.hms(read))
                    .font(ReceiptFont.mono(15, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.mintBright)
                Text("read")
                    .font(ReceiptFont.mono(11))
                    .foregroundStyle(DS.Palette.Reclaim.muted)
            }
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.Reclaim.hairline).frame(height: 1)
        }
    }

    private func miniBar(fraction: Double, fill: Color) -> some View {
        LinearProgressBar(fraction: fraction, height: 6, fill: fill, track: DS.Palette.Reclaim.track, animated: false)
    }

    private var empty: some View {
        VStack(spacing: DS.Spacing.md) {
            Text("LIFETIME").font(ReceiptFont.mono(11)).kerning(2)
                .foregroundStyle(DS.Palette.Reclaim.muted)
            Text("No stats yet")
                .font(BrandFont.display(24, .bold))
                .foregroundStyle(DS.Palette.Reclaim.text)
            Text("Listen with SmartSpeech or read an e-book\nand your stats show up here.")
                .font(ReceiptFont.mono(12))
                .foregroundStyle(DS.Palette.Reclaim.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    static let saved = DS.Palette.Reclaim.mintBright
    static let ebookAccent = Color.adaptive(light: 0xC47D2A, dark: 0xE8A855)

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

private struct NerdStatsCoverThumb: View {
    let coverPath: String?
    let placeholderIcon: String
    @State private var image: UIImage?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                shape.fill(DS.Palette.Reclaim.surface)
                    .overlay(Image(systemName: placeholderIcon)
                        .font(.system(size: 16)).foregroundStyle(DS.Palette.Reclaim.muted))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(shape)
        .task(id: coverPath) {
            image = nil
            guard let coverPath else { return }
            image = await CoverImageLoader.Cache.shared.load(
                relativePath: coverPath,
                maxPixelSize: 44 * 3
            )?.image
        }
    }
}
