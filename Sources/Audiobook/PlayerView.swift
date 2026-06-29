import SwiftData
import SwiftUI
import UIKit

/// Full-screen audiobook player: artwork, scrubber, transport, speed, and a
/// chapter/track list. Resume is handled by `AudiobookPlayer`.
struct PlayerView: View {
    let audiobook: Audiobook
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncManager.self) private var sync
    @State private var player = AudiobookPlayer()
    @State private var showTracks = false
    @State private var showCadence = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private let speeds: [Float] = [0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        VStack(spacing: DS.Spacing.lg) {
            cover
            VStack(spacing: DS.Spacing.xs) {
                Text(player.currentTrack?.title ?? audiobook.title)
                    .font(.headline).multilineTextAlignment(.center)
                if let author = audiobook.author {
                    Text(author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            scrubber
            transport
            speedPicker
            Button {
                showTracks = true
            } label: {
                Label("Chapters", systemImage: "list.bullet")
            }
        }
        .padding(DS.Spacing.lg)
        .navigationTitle(audiobook.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { player.load(audiobook, context: modelContext) }
        .onDisappear {
            player.teardown()   // persists the final position locally
            // Then push it for cross-device resume. Capture the key (a String) up
            // front — the Audiobook model is not Sendable across the actor hop.
            let key = audiobook.sourcePath
            Task { await sync.pushAudiobookProgress(sourcePath: key) }
        }
        .sheet(isPresented: $showTracks) {
            TrackListView(player: player)
        }
        .sheet(isPresented: $showCadence) {
            CadenceSettingsView(book: audiobook, player: player)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showCadence = true
                } label: {
                    Image(systemName: "timer")
                        .accessibilityLabel("\(CadenceBranding.featureName) settings")
                }
            }
        }
    }

    private var cover: some View {
        Group {
            if let rel = audiobook.coverPath,
               let url = try? ContainerPaths.url(forRelativePath: rel),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .fill(DS.Palette.coverPlaceholder)
                    .overlay(Image(systemName: "headphones").font(.largeTitle).foregroundStyle(.secondary))
            }
        }
        .frame(maxHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private var scrubber: some View {
        VStack(spacing: DS.Spacing.xs) {
            Slider(
                value: Binding(
                    get: { scrubbing ? scrubValue : player.offsetInTrack },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(player.trackDuration, 1),
                onEditingChanged: { editing in
                    scrubbing = editing
                    if !editing { player.seekInTrack(to: scrubValue) }
                }
            )
            HStack {
                Text(Self.fmt(scrubbing ? scrubValue : player.offsetInTrack))
                Spacer()
                Text(Self.fmt(player.trackDuration))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var transport: some View {
        HStack(spacing: DS.Spacing.xl) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
            // Space bar = play/pause on hardware keyboard (iPad + Mac Catalyst).
            // Additive — has no effect on iPhone where no keyboard is attached.
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .resizable().frame(width: 64, height: 64)
            }
            .keyboardShortcut(.space, modifiers: [])
            Button { player.skip(30) } label: { Image(systemName: "goforward.30") }
        }
        .font(.title)
    }

    private var speedPicker: some View {
        Picker("Speed", selection: $player.rate) {
            ForEach(speeds, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
        }
        .pickerStyle(.segmented)
    }

    static func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
