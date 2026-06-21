import SwiftUI

/// Chapter / track list with tap-to-jump. Highlights the current track.
struct TrackListView: View {
    let player: AudiobookPlayer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(player.tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    player.jump(toTrack: index)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: index == player.currentIndex ? "play.fill" : "\(index + 1).circle")
                            .foregroundStyle(index == player.currentIndex ? DS.Palette.accent : .secondary)
                        Text(track.title).lineLimit(1)
                        Spacer()
                        Text(PlayerView.fmt(track.duration))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
