import SwiftData
import SwiftUI
import UIKit

private enum PlayerPresentedSheet: Identifiable, Hashable {
    case chapters
    case thisBookStats
    case smartSpeech
    var id: Self { self }
}

struct PlayerView: View {
    let audiobook: Audiobook
    var previewMode = false
    var coverNamespace: Namespace.ID? = nil

    init(audiobook: Audiobook, previewMode: Bool = false, coverNamespace: Namespace.ID? = nil) {
        self.init(audiobook: audiobook, previewMode: previewMode, previewSheet: nil, coverNamespace: coverNamespace)
    }

    private init(audiobook: Audiobook, previewMode: Bool, previewSheet: PlayerPresentedSheet?, coverNamespace: Namespace.ID?) {
        self.audiobook = audiobook
        self.previewMode = previewMode
        self.coverNamespace = coverNamespace
        _presentedSheet = State(initialValue: previewSheet)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(AudiobookPlayer.self) private var player

    @State private var presentedSheet: PlayerPresentedSheet?

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        GeometryReader { geo in
            let contentWidth = max(geo.size.width - 40, 0)
            let reservedChrome: CGFloat = 280
            let maxByHeight = max(geo.size.height - reservedChrome, 120)
            let widthCap = hSizeClass == .regular ? 520 : contentWidth
            let side = min(contentWidth, widthCap, maxByHeight)
            VStack(spacing: 0) {
                PlayerCoverArt(audiobook: audiobook, side: side, coverNamespace: coverNamespace)
                PlayerMetaBlock(audiobook: audiobook, onPresentChapters: { presentedSheet = .chapters })
                    .padding(.top, 14)
                Spacer(minLength: 16)
                PlayerTransport()
                dock.padding(.top, 22)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .background(LinearGradient(colors: [C.bg1, C.bg2], startPoint: .top, endPoint: .bottom))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(C.bg1, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .tint(C.mint)
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .chapters:
                PlayerChaptersSheet()
                    .environment(player)
            case .thisBookStats:
                PlayerThisBookStatsSheet(audiobook: audiobook)
                    .environment(player)
            case .smartSpeech:
                SmartSpeechSheet(book: audiobook, player: player)
            }
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

    private var dock: some View {
        GlassEffectContainer {
            HStack(spacing: 30) {
                Button { presentedSheet = .smartSpeech } label: {
                    Image(systemName: "speedometer").font(.system(size: 21))
                        .foregroundStyle(C.muted)
                }
                .hoverEffect(.highlight)
                .accessibilityLabel("SmartSpeech — speed and trimming")

                AudioRoutePickerButton(tint: UIColor(C.text), activeTint: UIColor(C.mint))
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("AirPlay")

                sleepTimerControl

                Menu {
                    Button { presentedSheet = .chapters } label: { Label("Chapters", systemImage: "list.bullet") }
                    Button { presentedSheet = .thisBookStats } label: { Label("This-book stats", systemImage: "chart.bar.xaxis") }
                    Button { presentedSheet = .smartSpeech } label: { Label("SmartSpeech", systemImage: "speedometer") }
                    sleepTimerMenu
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(C.muted)
                }
                .hoverEffect(.highlight)
                .accessibilityLabel("More")
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
    @Environment(\.displayScale) private var displayScale
    @State private var coverImage: UIImage?

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
        .task(id: audiobook.coverPath) {
            coverImage = nil
            guard let path = audiobook.coverPath else { return }
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

private struct PlayerChaptersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudiobookPlayer.self) private var player

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.tracks.enumerated()), id: \.element.id) { i, track in
                        Button {
                            player.jump(toTrack: i)
                            dismiss()
                        } label: {
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
                            .padding(.horizontal, 20)
                            .overlay(alignment: .bottom) { Rectangle().fill(C.hairline).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(LinearGradient(colors: [C.bg1, C.bg2], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(C.bg1, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(C.mint)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct PlayerThisBookStatsSheet: View {
    let audiobook: Audiobook
    @Environment(\.dismiss) private var dismiss
    @Environment(AudiobookPlayer.self) private var player

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    var body: some View {
        let played = audiobook.listenedSeconds ?? 0
        let saved = audiobook.smartSpeechSavedSeconds ?? 0
        let pct = played > 0 ? Int((saved / played * 100).rounded()) : 0
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(LinearGradient(colors: [C.bg1, C.bg2], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("This book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(C.bg1, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(C.mint)
                }
            }
        }
        .presentationDragIndicator(.visible)
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
    let onPresentChapters: () -> Void
    @Environment(AudiobookPlayer.self) private var player
    @State private var scrubbing = false
    @State private var scrubFraction: Double = 0

    private var C: DS.Palette.Reclaim.Type { DS.Palette.Reclaim.self }

    private var canSkipToNextSegment: Bool {
        player.segmentCount > 1 && player.currentIndex < player.tracks.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("AUDIOBOOK")
                .font(ReceiptFont.mono(11)).kerning(1).foregroundStyle(C.muted)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(audiobook.title)
                .font(BrandFont.display(22, .bold)).foregroundStyle(C.text)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 7)
            if player.segmentCount > 1 {
                Text("\(player.segmentNoun.uppercased()) \(player.currentSegmentNumber)")
                    .font(ReceiptFont.mono(11)).kerning(1).foregroundStyle(C.muted)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 7)
            }

            HStack(spacing: 14) {
                Button(action: onPresentChapters) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(C.muted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityLabel("Chapters")

                ThinScrubber(
                    fraction: scrubbing ? scrubFraction : player.bookProgress,
                    onChanged: { scrubbing = true; scrubFraction = $0 },
                    onEnded: { f in
                        scrubbing = false
                        player.seekInBook(to: f * player.totalDuration)
                    }
                )

                Button { player.jump(toTrack: player.currentIndex + 1) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(canSkipToNextSegment ? C.muted : C.muted.opacity(0.35))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(!canSkipToNextSegment)
                .accessibilityLabel("Next chapter")
            }
            .padding(.top, 12)

            PlayerElapsedTimes(
                scrubbing: scrubbing,
                scrubFraction: scrubFraction
            )
            .padding(.top, 10)
        }
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
        HStack(spacing: 40) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 33))
                    .foregroundStyle(C.text)
            }
            .hoverEffect(.highlight)
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(C.mint).frame(width: 84, height: 84)
                        .shadow(color: C.mint.opacity(0.4), radius: 12, y: 6)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .bold)).foregroundStyle(C.onMint)
                }
            }
            .hoverEffect(.highlight)
            .keyboardShortcut(.space, modifiers: [])
            Button { player.skip(30) } label: {
                Image(systemName: "goforward.30").font(.system(size: 33))
                    .foregroundStyle(C.text)
            }
            .hoverEffect(.highlight)
        }
    }
}

private struct ThinScrubber: View {
    let fraction: Double
    let onChanged: (Double) -> Void
    let onEnded: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = min(1, max(0, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.Reclaim.track)
                Capsule().fill(DS.Palette.Reclaim.mint)
                    .frame(width: max(0, w * f))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in onChanged(min(1, max(0, v.location.x / max(w, 1)))) }
                    .onEnded { v in onEnded(min(1, max(0, v.location.x / max(w, 1)))) }
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("Book progress")
        .accessibilityValue("\(Int(min(1, max(0, fraction)) * 100)) percent")
    }
}

#if DEBUG
fileprivate extension PlayerView {
    static func preview(audiobook: Audiobook, sheet: PlayerPresentedSheet? = nil) -> PlayerView {
        PlayerView(audiobook: audiobook, previewMode: true, previewSheet: sheet, coverNamespace: nil)
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
                let previewSheet: PlayerPresentedSheet? = args.contains("-page2") ? .thisBookStats
                    : (args.contains("-page1") ? .chapters : nil)
                TabView {
                    NavigationStack {
                        PlayerView.preview(audiobook: book, sheet: previewSheet)
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
