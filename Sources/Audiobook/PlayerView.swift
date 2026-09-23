import SwiftData
import SwiftUI
import UIKit

/// Full-screen player: swipe the cover for Chapters and This-book stats, thick book-domain
/// scrubber, and Overcast-style chrome (dismiss at the bottom left, play/pause as an icon).
struct PlayerView: View {
    let audiobook: Audiobook
    var previewMode = false
    var coverNamespace: Namespace.ID? = nil
    var onDismiss: (() -> Void)? = nil

    init(
        audiobook: Audiobook,
        previewMode: Bool = false,
        initialPage: Int = 0,
        coverNamespace: Namespace.ID? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        self.audiobook = audiobook
        self.previewMode = previewMode
        self.coverNamespace = coverNamespace
        self.onDismiss = onDismiss
        _coverPage = State(initialValue: initialPage)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(AudiobookPlayer.self) private var player

    @State private var coverPage = 0
    @State private var showSmartSpeech = false
    @State private var showHardcoverMatch = false

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = max(geo.size.width - 40, 0)
            let reservedChrome: CGFloat = 300
            let maxByHeight = max(geo.size.height - reservedChrome, 120)
            let widthCap = hSizeClass == .regular ? 520 : contentWidth
            let side = min(contentWidth, widthCap, maxByHeight)
            VStack(spacing: 0) {
                coverPager(side: side)
                dots.padding(.top, 12)
                PlayerMetaBlock(audiobook: audiobook, savedSeconds: savedSeconds)
                    .padding(.top, 12)
                Spacer(minLength: 16)
                PlayerTransport()
                    .padding(.bottom, 18)
                bottomChrome
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 2)
        }
        .background(LinearGradient(colors: [C.bg1, C.bg2], startPoint: .top, endPoint: .bottom))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(onDismiss == nil ? .automatic : .hidden, for: .navigationBar)
        .toolbarBackground(C.bg1, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .tint(C.mint)
        .sheet(isPresented: $showSmartSpeech) {
            SmartSpeechSheet(book: audiobook, player: player)
        }
        .sheet(isPresented: $showHardcoverMatch) {
            HardcoverMatchSheet(book: audiobook)
        }
        .onAppear { if !previewMode { player.load(audiobook, context: modelContext) } }
        .onDisappear {
            guard !previewMode else { return }
            player.savePosition()
            let key = audiobook.sourcePath
            Task { await sync.pushAudiobookProgress(sourcePath: key) }
        }
        .focusedValue(\.audiobookPlayer, player)
    }

    private func coverPager(side: CGFloat) -> some View {
        TabView(selection: $coverPage) {
            PlayerCoverArt(audiobook: audiobook, side: side, coverNamespace: coverNamespace).tag(0)
            PlayerChaptersPanel(side: side).tag(1)
            PlayerThisBookPanel(audiobook: audiobook, side: side).tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: side)
        .accessibilityLabel(coverPage == 0 ? "Cover" : coverPage == 1 ? "Chapters" : "This-book stats")
    }

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i == coverPage ? C.mint : C.muted.opacity(0.4))
                    .frame(width: i == coverPage ? 18 : 6, height: 6)
                    .onTapGesture { withAnimation { coverPage = i } }
                    .accessibilityLabel(i == 0 ? "Cover" : i == 1 ? "Chapters" : "This-book stats")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player pages")
    }

    private var savedSeconds: Double { audiobook.smartSpeechSavedSeconds ?? 0 }

    private var bottomChrome: some View {
        VStack(spacing: 10) {
            Text(player.outputRouteName)
                .font(ReceiptFont.mono(10)).kerning(1.2)
                .foregroundStyle(C.muted)
                .lineLimit(1)
                .accessibilityLabel("Playing on \(player.outputRouteName)")

            if HardcoverSettings.isActive { hardcoverBadge }

            ZStack {
                if let onDismiss {
                    HStack {
                        Button(action: onDismiss) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(C.text)
                                .frame(width: 44, height: 44)
                                .background(C.surface, in: Circle())
                                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
                        }
                        .buttonStyle(.plain)
                        .hoverEffect(.highlight)
                        .accessibilityLabel("Close player")
                        Spacer(minLength: 0)
                    }
                }
                dock
            }
        }
        .padding(.bottom, 4)
        .onAppear { player.refreshOutputRoute() }
    }

    /// Shows what this book is tracked as on Hardcover, and offers to fix it if we guessed.
    @ViewBuilder
    private var hardcoverBadge: some View {
        Button {
            showHardcoverMatch = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: audiobook.hardcoverEditionId == nil
                      ? "books.vertical" : "checkmark.seal.fill")
                Text(audiobook.hardcoverEditionId == nil
                     ? "Match on Hardcover"
                     : "Tracked on Hardcover")
            }
            .font(ReceiptFont.mono(10))
            .kerning(1.1)
            .foregroundStyle(audiobook.hardcoverEditionId == nil ? C.muted : C.mint)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private var dock: some View {
        GlassEffectContainer {
            HStack(spacing: 30) {
                Button { showSmartSpeech = true } label: {
                    Image(systemName: "speedometer").font(.system(size: 21))
                        .foregroundStyle(C.muted)
                }
                .hoverEffect(.highlight)
                .accessibilityLabel("SmartSpeech — speed and trimming")

                AudioRoutePickerButton(tint: UIColor(C.text), activeTint: UIColor(C.mint))
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("AirPlay")

                sleepTimerControl
            }
            .frame(height: 26)
            .padding(.vertical, 12)
            .padding(.horizontal, 28)
        }
        .glassEffect()
    }

    private var sleepTimerControl: some View {
        Menu {
            sleepTimerMenu
        } label: {
            Image(systemName: player.sleepTimerEnd != nil ? "moon.zzz.fill" : "moon.zzz")
                .font(.system(size: 21))
                .foregroundStyle(player.sleepTimerEnd != nil ? C.mint : C.muted)
        }
        .hoverEffect(.highlight)
        .accessibilityLabel(player.sleepTimerRemainingLabel.map { "Sleep timer, \($0) remaining" }
            ?? "Sleep timer")
    }

    @ViewBuilder
    private var sleepTimerMenu: some View {
        Button("Off") { player.cancelSleepTimer() }
        Divider()
        ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
            Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
        }
    }

    static func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func fmtClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let t = Int(seconds), h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

private struct PlayerCoverArt: View {
    let audiobook: Audiobook
    let side: CGFloat
    var coverNamespace: Namespace.ID? = nil
    @Environment(AudiobookPlayer.self) private var player
    @Environment(\.displayScale) private var displayScale
    @State private var coverImage: UIImage?

    private var coverPath: String? { audiobook.coverPath ?? player.book?.coverPath }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Group {
            if let coverImage {
                Image(uiImage: coverImage).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(hex: 0x3A2360), Color(hex: 0x180F2B)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "headphones").font(.system(size: 54)).foregroundStyle(.white.opacity(0.5)))
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .modifier(PlayerMatchedCoverEffect(id: "nowPlayingCover", namespace: coverNamespace))
        .shadow(color: .black.opacity(0.5), radius: 22, y: 14)
        .padding(.horizontal, 2)
        .task(id: coverPath) {
            coverImage = nil
            guard let path = coverPath else { return }
            let pixels = side * displayScale * 2
            coverImage = await CoverImageLoader.Cache.shared.load(
                relativePath: path,
                maxPixelSize: pixels
            )?.image
        }
    }
}

private struct PlayerMatchedCoverEffect: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct PlayerChaptersPanel: View {
    let side: CGFloat
    @Environment(AudiobookPlayer.self) private var player

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        PlayerPanelSurface(side: side) {
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
                                Text(PlayerView.fmt(track.duration)).font(ReceiptFont.mono(11))
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
}

private struct PlayerThisBookPanel: View {
    let audiobook: Audiobook
    let side: CGFloat
    @Environment(AudiobookPlayer.self) private var player

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        let played = audiobook.listenedSeconds ?? 0
        let saved = audiobook.smartSpeechSavedSeconds ?? 0
        let pct = played > 0 ? Int((saved / played * 100).rounded()) : 0
        PlayerPanelSurface(side: side) {
            Text("This book").font(BrandFont.display(18, .bold)).foregroundStyle(C.text)
            Text(NerdStatsView.hms(saved)).font(BrandFont.display(30, .heavy))
                .foregroundStyle(C.mintBright).padding(.top, 8)
            Text("RECLAIMED · \(pct)%").font(ReceiptFont.mono(10)).kerning(1.5)
                .foregroundStyle(C.muted).padding(.top, 6)
            VStack(spacing: 0) {
                PlayerKVRow(label: "Listened", value: NerdStatsView.hms(played))
                PlayerKVRow(label: "Silence saved", value: "−\(NerdStatsView.hms(saved))", color: C.mint)
                PlayerKVRow(label: "% saved", value: "\(pct)%")
                PlayerKVRow(label: "Speed", value: String(format: "%g×", player.rate))
            }
            .padding(.top, 16)
            Spacer(minLength: 0)
        }
    }
}

private struct PlayerPanelSurface<Content: View>: View {
    let side: CGFloat
    @ViewBuilder var content: Content

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: { content })
            .padding(18)
            .frame(width: side, height: side, alignment: .topLeading)
            .background(C.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 2)
    }
}

private struct PlayerKVRow: View {
    let label: String
    let value: String
    var color: Color?

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        HStack {
            Text(label).font(ReceiptFont.mono(13)).foregroundStyle(C.muted)
            Spacer(minLength: 8)
            Text(value).font(ReceiptFont.mono(14, .medium)).foregroundStyle(color ?? C.text)
        }
        .padding(.vertical, 5)
    }
}

private struct PlayerMetaBlock: View {
    let audiobook: Audiobook
    let savedSeconds: Double
    @Environment(AudiobookPlayer.self) private var player
    @State private var scrubbing = false
    @State private var scrubFraction: Double = 0

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
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
                onEnded: { f in
                    scrubbing = false
                    player.seekInBook(to: f * player.totalDuration)
                }
            )
            .padding(.top, 8)

            PlayerElapsedTimes(
                scrubbing: scrubbing,
                scrubFraction: scrubFraction
            )
            .padding(.top, 10)
        }
    }

    private var chapterLine: String {
        let name = (player.currentTrack?.title ?? audiobook.author ?? "").uppercased()
        if player.segmentCount > 1 {
            return "\(player.segmentNoun.uppercased()) \(player.currentSegmentNumber) · \(name)"
        }
        return name
    }
}

private struct PlayerElapsedTimes: View {
    let scrubbing: Bool
    let scrubFraction: Double
    @Environment(AudiobookPlayer.self) private var player

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    private var displayedElapsed: Double {
        scrubbing ? scrubFraction * player.totalDuration : player.bookPosition
    }

    var body: some View {
        HStack {
            Text(PlayerView.fmtClock(displayedElapsed))
            Spacer()
            Text("−\(PlayerView.fmtClock(max(0, player.totalDuration - displayedElapsed)))")
        }
        .font(ReceiptFont.mono(12)).foregroundStyle(C.muted)
    }
}

private struct PlayerTransport: View {
    @Environment(AudiobookPlayer.self) private var player

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        HStack(spacing: 44) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 33))
                    .foregroundStyle(C.text)
            }
            .hoverEffect(.highlight)
            .accessibilityLabel("Skip back 15 seconds")

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(C.text)
                    .offset(x: player.isPlaying ? 0 : 3)
                    .frame(width: 56, height: 56)
                    .contentShape(Rectangle())
            }
            .hoverEffect(.highlight)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button { player.skip(30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 33))
                    .foregroundStyle(C.text)
            }
            .hoverEffect(.highlight)
            .accessibilityLabel("Skip forward 30 seconds")
        }
    }
}

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
fileprivate extension PlayerView {
    static func preview(audiobook: Audiobook, page: Int = 0) -> PlayerView {
        PlayerView(audiobook: audiobook, previewMode: true, initialPage: page, coverNamespace: nil)
    }
}

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
                TabView {
                    NavigationStack {
                        PlayerView.preview(audiobook: book, page: page)
                            .environment(player)
                    }
                    .tabItem { Label("Audiobooks", systemImage: "headphones") }
                    Text("E-books").tabItem { Label("E-books", systemImage: "books.vertical") }
                }
            }
        }
    }
}

#Preview("Now Playing") {
    PlayerNowPlayingPreviewHost()
}

private struct PlayerNowPlayingPreviewHost: View {
    private let book: Audiobook = {
        let book = Audiobook(title: "Harry Potter and the Prisoner of Azkaban (Full-Cast Edition)",
                             sourcePath: "preview")
        book.author = "J. K. Rowling"
        book.listenedSeconds = 11_520
        book.smartSpeechSavedSeconds = 1_470
        book.totalDuration = 40_000
        return book
    }()

    private let tracks = [
        AudiobookTrack(title: "Opening Credits", fileRelPath: "a", duration: 64, order: 0),
        AudiobookTrack(title: "Owl Post", fileRelPath: "b", duration: 1_468, order: 1),
        AudiobookTrack(title: "Aunt Marge’s Big Mistake", fileRelPath: "c", duration: 1_514, order: 2),
        AudiobookTrack(title: "The Knight Bus", fileRelPath: "d", duration: 1_634, order: 3),
        AudiobookTrack(title: "The Dementor", fileRelPath: "e", duration: 2_477, order: 4),
        AudiobookTrack(title: "Talons and Tea Leaves", fileRelPath: "f", duration: 2_517, order: 5),
    ]

    @State private var player = AudiobookPlayer()
    @State private var sync: SyncManager = {
        let schema = Schema(AppSchema.models)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
        return SyncManager(source: MockLibrarySource(), context: container.mainContext)
    }()

    var body: some View {
        NavigationStack {
            PlayerView.preview(audiobook: book)
                .environment(player)
                .environment(sync)
        }
        .onAppear {
            player.rate = 1.5
            player.debugMockPresent(book: book, tracks: tracks, currentIndex: 4, offsetInTrack: 900, isPlaying: false)
        }
    }
}
#endif
