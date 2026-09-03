import SwiftUI

/// Focused audiobook player for menu-bar / keyboard commands (Mac Catalyst).
struct FocusedAudiobookPlayerKey: FocusedValueKey {
    typealias Value = AudiobookPlayer
}

extension FocusedValues {
    var audiobookPlayer: AudiobookPlayer? {
        get { self[FocusedAudiobookPlayerKey.self] }
        set { self[FocusedAudiobookPlayerKey.self] = newValue }
    }
}

#if targetEnvironment(macCatalyst)
struct PlaybackCommands: Commands {
    @FocusedValue(\.audiobookPlayer) private var player

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play / Pause") {
                player?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player == nil)

            Button("Skip Back 15 Seconds") {
                player?.skip(-15)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            .disabled(player == nil)

            Button("Skip Forward 30 Seconds") {
                player?.skip(30)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            .disabled(player == nil)
        }
    }
}
#endif
