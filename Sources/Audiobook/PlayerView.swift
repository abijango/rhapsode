import SwiftData
import SwiftUI
import UIKit

/// The "Reclaimed" full-screen player: a dominant cover that swipes to Chapters then This-book stats,
/// a single book-domain thick progress bar, a lowered transport, and a slim SmartSpeech · AirPlay ·
/// More dock. Always-dark Ink & Mint; Hanken display + IBM Plex Mono data. Playback lives in the
/// app-lifetime `AudiobookPlayer` (injected), so it continues as the user navigates away.
struct PlayerView: View {
    let audiobook: Audiobook
    /// DEBUG preview: skip the `onAppear` load so a mock player's injected state survives (for
    /// screenshotting the chrome without real audio).
    var previewMode = false

    init(audiobook: Audiobook, previewMode: Bool = false, initialPage: Int = 0) {
        self.audiobook = audiobook
        self.previewMode = previewMode
        _coverPage = State(initialValue: initialPage)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(AudiobookPlayer.self) private var player

    @State private var coverPage = 0
    @State private var showSmartSpeech = false
    @State private var scrubbing = false
    @State private var scrubFraction: Double = 0

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = geo.size.width - 40
            let side = min(contentWidth, hSizeClass == .regular ? 520 : contentWidth)
            VStack(spacing: 0) {
                coverPager(side: side)
                dots.padding(.top, 14)
                metaBlock.padding(.top, 14)
                Spacer(minLength: 16)
                transport
                dock.padding(.top, 22)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .background(LinearGradient(colors: [C.bg1, C.bg2], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(C.bg1, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        // Full-screen now-playing: hide the bottom tab bar while the player is pushed.
        // Swipe back (interactive pop) returns to the shelf, where the tabs live.
        .toolbar(.hidden, for: .tabBar)
        .tint(C.mint)
        .sheet(isPresented: $showSmartSpeech) {
            SmartSpeechSheet(book: audiobook, player: player)
        }
        .onAppear { if !previewMode { player.load(audiobook, context: modelContext) } }
        .onDisappear {
            guard !previewMode else { return }
            player.savePosition()
            let key = audiobook.sourcePath
            Task { await sync.pushAudiobookProgress(sourcePath: key) }
        }
    }

    // MARK: Cover pager (cover → chapters → this-book stats)

    private func coverPager(side: CGFloat) -> some View {
        TabView(selection: $coverPage) {
            coverArt(side: side).tag(0)
            chaptersPanel(side: side).tag(1)
            thisBookPanel(side: side).tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: side)
    }

    private func coverArt(side: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Group {
            if let rel = audiobook.coverPath,
               let url = try? ContainerPaths.url(forRelativePath: rel),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: 0x3A2360), Color(hex: 0x180F2B)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "headphones").font(.system(size: 54)).foregroundStyle(.white.opacity(0.5)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.5), radius: 22, y: 14)
        .padding(.horizontal, 2)
    }

    private func chaptersPanel(side: CGFloat) -> some View {
        panelSurface(side: side) {
            Text("Chapters").font(BrandFont.display(18, .bold)).foregroundStyle(C.text)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.tracks.enumerated()), id: \.element.id) { i, track in
                        Button { withAnimation { player.jump(toTrack: i) } } label: {
                            HStack(spacing: 10) {
                                Text(String(format: "%02d", i + 1))
                                    .font(ReceiptFont.mono(11, .medium))
                                    .foregroundStyle(i == player.currentIndex ? C.mint : C.muted)
                                Text(track.title).font(BrandFont.display(14, .medium)).lineLimit(1)
                                    .foregroundStyle(i == player.currentIndex ? C.mint : C.text)
                                Spacer(minLength: 8)
                                Text(Self.fmt(track.duration)).font(ReceiptFont.mono(11))
                                    .foregroundStyle(C.muted)
                            }
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { Rectangle().fill(C.hairline).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func thisBookPanel(side: CGFloat) -> some View {
        let played = audiobook.listenedSeconds ?? 0
        let saved = audiobook.smartSpeechSavedSeconds ?? 0
        let pct = played > 0 ? Int((saved / played * 100).rounded()) : 0
        return panelSurface(side: side) {
            Text("This book").font(BrandFont.display(18, .bold)).foregroundStyle(C.text)
            Text(NerdStatsView.hms(saved)).font(BrandFont.display(30, .heavy))
                .foregroundStyle(C.mintBright).padding(.top, 8)
            Text("RECLAIMED · \(pct)%").font(ReceiptFont.mono(10)).kerning(1.5)
                .foregroundStyle(C.muted).padding(.top, 6)
            VStack(spacing: 0) {
                kv("Listened", NerdStatsView.hms(played))
                kv("Silence saved", "−\(NerdStatsView.hms(saved))", color: C.mint)
                kv("% saved", "\(pct)%")
                kv("Speed", String(format: "%g×", player.rate))
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
        }
    }

    private func kv(_ label: String, _ value: String, color: Color? = nil) -> some View {
        HStack {
            Text(label).font(ReceiptFont.mono(13)).foregroundStyle(C.muted)
            Spacer(minLength: 8)
            Text(value).font(ReceiptFont.mono(14, .medium)).foregroundStyle(color ?? C.text)
        }
        .padding(.vertical, 5)
    }

    private func panelSurface<Content: View>(side: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(18)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(C.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 2)
    }

    // MARK: Page dots (tappable — the Mac Catalyst swipe fallback)

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == coverPage ? C.mint : C.muted.opacity(0.4))
                    .frame(width: i == coverPage ? 18 : 6, height: 6)
                    .onTapGesture { withAnimation { coverPage = i } }
            }
        }
    }

    // MARK: Meta (title, chapter, reclaimed, scrubber, times)

    private var metaBlock: some View {
        VStack(spacing: 0) {
            Text(player.currentTrack?.title ?? audiobook.title)
                .font(BrandFont.display(22, .bold)).foregroundStyle(C.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(chapterLine)
                .font(ReceiptFont.mono(11)).kerning(1).foregroundStyle(C.muted)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)

            if savedSeconds >= 1 {
                Text("◆ \(NerdStatsView.hms(savedSeconds)) reclaimed")
                    .font(ReceiptFont.mono(11, .semibold)).foregroundStyle(C.mint)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 12)
            } else {
                Color.clear.frame(height: 1).padding(.top, 12)
            }

            ThickScrubber(
                fraction: scrubbing ? scrubFraction : player.bookProgress,
                onChanged: { scrubbing = true; scrubFraction = $0 },
                onEnded: { f in scrubbing = false; player.seekInBook(to: f * player.totalDuration) }
            )
            .padding(.top, 8)

            HStack {
                Text(Self.fmtClock(displayedElapsed))
                Spacer()
                Text("−\(Self.fmtClock(max(0, player.totalDuration - displayedElapsed)))")
            }
            .font(ReceiptFont.mono(12)).foregroundStyle(C.muted)
            .padding(.top, 10)
        }
    }

    private var displayedElapsed: Double {
        scrubbing ? scrubFraction * player.totalDuration : player.bookPosition
    }

    private var savedSeconds: Double { audiobook.smartSpeechSavedSeconds ?? 0 }

    private var chapterLine: String {
        let name = (player.currentTrack?.title ?? audiobook.author ?? "").uppercased()
        if player.segmentCount > 1 {
            return "\(player.segmentNoun.uppercased()) \(player.currentSegmentNumber) · \(name)"
        }
        return name
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 40) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 33))
                    .foregroundStyle(C.text)
            }
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(C.mint).frame(width: 84, height: 84)
                        .shadow(color: C.mint.opacity(0.4), radius: 12, y: 6)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .bold)).foregroundStyle(C.onMint)
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { player.skip(30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 33))
                    .foregroundStyle(C.text)
            }
        }
    }

    // MARK: Dock (SmartSpeech · AirPlay · More)

    private var dock: some View {
        HStack(spacing: 30) {
            Button { showSmartSpeech = true } label: {
                Image(systemName: "speedometer").font(.system(size: 21))
                    .foregroundStyle(C.muted)
            }
            .accessibilityLabel("SmartSpeech — speed and trimming")

            AudioRoutePickerButton(tint: UIColor(C.text), activeTint: UIColor(C.mint))
                .frame(width: 28, height: 28)
                .accessibilityLabel("AirPlay")

            Menu {
                Button { withAnimation { coverPage = 1 } } label: { Label("Chapters", systemImage: "list.bullet") }
                Button { withAnimation { coverPage = 2 } } label: { Label("This-book stats", systemImage: "chart.bar.xaxis") }
                Button { showSmartSpeech = true } label: { Label("SmartSpeech", systemImage: "speedometer") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(C.muted)
            }
            .accessibilityLabel("More")
        }
        .frame(height: 26)
        .padding(.vertical, 12)
        .padding(.horizontal, 28)
        .background(C.fill, in: Capsule())
        .overlay(Capsule().stroke(C.stroke))
    }

    // MARK: Formatting

    /// "M:SS" (used by TrackListView too).
    static func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "H:MM:SS" for long book positions, "M:SS" under an hour.
    static func fmtClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds), h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// A thick, book-domain scrub bar (round knob) matching the "Reclaimed" look. Reports scrub fraction
/// live while dragging and the final fraction on release; the caller maps it to a book-domain seek.
private struct ThickScrubber: View {
    let fraction: Double
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = min(1, max(0, fraction))
            let knobX = f * max(w - 22, 0)
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.Reclaim.track)
                Capsule().fill(DS.Palette.Reclaim.mint).frame(width: knobX + 11)
                Circle().fill(DS.Palette.Reclaim.knob).frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .offset(x: knobX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onChanged(min(1, max(0, v.location.x / max(w, 1)))) }
                    .onEnded { v in onEnded(min(1, max(0, v.location.x / max(w, 1)))) }
            )
        }
        .frame(height: 22)
        .accessibilityElement()
        .accessibilityLabel("Book progress")
        .accessibilityValue("\(Int(min(1, max(0, fraction)) * 100)) percent")
    }
}

#if DEBUG
/// DEBUG-only harness to screenshot the player chrome without real audio (launch arg `-previewplayer`).
struct PlayerPreviewHarness: View {
    var body: some View {
        let book = Audiobook(title: "Harry Potter and the Prisoner of Azkaban (Full-Cast Edition)",
                             sourcePath: "preview")
        book.author = "J. K. Rowling"
        book.listenedSeconds = 11_520
        book.smartSpeechSavedSeconds = 1_470
        book.totalDuration = 40_000
        let tracks = [
            AudiobookTrack(title: "Opening Credits", fileRelPath: "a", duration: 64, order: 0),
            AudiobookTrack(title: "Owl Post", fileRelPath: "b", duration: 1_468, order: 1),
            AudiobookTrack(title: "Aunt Marge’s Big Mistake", fileRelPath: "c", duration: 1_514, order: 2),
            AudiobookTrack(title: "The Knight Bus", fileRelPath: "d", duration: 1_634, order: 3),
            AudiobookTrack(title: "The Dementor", fileRelPath: "e", duration: 2_477, order: 4),
            AudiobookTrack(title: "Talons and Tea Leaves", fileRelPath: "f", duration: 2_517, order: 5),
        ]
        let player = AudiobookPlayer()
        player.rate = 1.5
        player.debugMockPresent(book: book, tracks: tracks, currentIndex: 4, offsetInTrack: 900, isPlaying: false)
        let args = CommandLine.arguments
        return Group {
            if args.contains("-smartspeech") {
                SmartSpeechSheet(book: book, player: player)
            } else {
                let page = args.contains("-page2") ? 2 : (args.contains("-page1") ? 1 : 0)
                // Wrap in a TabView to mirror the real context and prove the player hides the tab bar.
                TabView {
                    NavigationStack {
                        PlayerView(audiobook: book, previewMode: true, initialPage: page)
                            .environment(player)
                    }
                    .tabItem { Label("Audiobooks", systemImage: "headphones") }
                    Text("E-books").tabItem { Label("E-books", systemImage: "books.vertical") }
                }
            }
        }
    }
}
#endif
