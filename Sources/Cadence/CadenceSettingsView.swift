import SwiftUI
import CadenceKit

/// Per-book Cadence (silence-trimming) control panel. Spec §9, §5.4.
///
/// Allows the user to enable/disable the feature globally and select the per-book
/// trimming sensitivity (Default / More / Aggressive). Helper text guides the choice:
/// fast natural narrators → Default; slow/deliberate → More/Aggressive.
///
/// Tier changes enqueue a background re-render via `CadenceRenderCoordinator`; a
/// "Preparing…" indicator is shown until `selectTrimmedSource` returns a valid rendition
/// for the new tier, at which point `player.applyCadenceChange()` swaps the audio
/// source seamlessly at the current mapped source position.
struct CadenceSettingsView: View {
    let book: Audiobook
    /// The live player — used to call `applyCadenceChange()` on toggle/tier changes.
    let player: AudiobookPlayer

    @Environment(\.modelContext) private var modelContext

    @State private var enabled = false
    /// True while a re-render for a new tier is in progress.
    @State private var isPreparing = false
    /// The tier currently being prepared (so the poll knows which tier to wait for).
    @State private var preparingTier: CadenceSettings.Preset?
    /// Polling task for the "Preparing…" state.
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Cadence") {
                Toggle("Enable \(CadenceBranding.featureName)", isOn: Binding(
                    get: { enabled },
                    set: { new in
                        enabled = new
                        CadencePreferences.isEnabled = new
                        if new {
                            // Feature turned ON: enqueue render for the current book.
                            let bookID = book.id
                            Task { await CadenceRenderCoordinator.shared.enqueue(bookID: bookID) }
                        } else {
                            // Feature turned OFF: revert to original at the current position.
                            cancelPolling()
                            isPreparing = false
                            player.applyCadenceChange()
                        }
                    }
                ))

                if enabled {
                    Picker(
                        "Trimming Sensitivity",
                        selection: Binding(
                            get: { book.effectiveCadenceTier },
                            set: { newTier in
                                guard newTier != book.effectiveCadenceTier else { return }
                                book.cadenceTier = newTier.rawValue
                                try? modelContext.save()
                                // Cancel any in-flight render for the old tier and enqueue the new one.
                                let bookID = book.id
                                Task {
                                    await CadenceRenderCoordinator.shared.cancel(bookID: bookID)
                                    await CadenceRenderCoordinator.shared.enqueue(bookID: bookID)
                                }
                                startPreparingPoll(for: newTier)
                            }
                        )
                    ) {
                        ForEach(CadenceSettings.Preset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isPreparing)

                    if isPreparing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(helperText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // WP7: show honest accumulated time-saved stat (renders "0 min saved" until
                    // trimmed playback accumulates savings; never shows a misleading "Preparing…").
                    Text(CadenceStats.formattedTotal())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            enabled = CadencePreferences.isEnabled
        }
        .onChange(of: enabled) { _, new in
            CadencePreferences.isEnabled = new
        }
        .onDisappear {
            cancelPolling()
        }
    }

    private var helperText: String {
        switch book.effectiveCadenceTier {
        case .default:
            return "Fast, natural narrators sound best on Default — subtle compression you may not notice."
        case .more:
            return "More compression for slower narrators; maintains clarity while improving pace."
        case .aggressive:
            return "Maximum compression; recommended for very slow or deliberate narration."
        }
    }

    // MARK: - Preparing-state poll

    /// Begin polling for a valid rendition for `tier`. When found, call `applyCadenceChange()`
    /// to swap the player source seamlessly, then clear the Preparing state.
    private func startPreparingPoll(for tier: CadenceSettings.Preset) {
        cancelPolling()
        isPreparing = true
        preparingTier = tier
        let bookID = book.id
        // For multi-file books, poll for the file the player is currently on; fall back to
        // the first track's file for the single-file M4B case or when no track is active.
        let relPath = player.currentTrack?.fileRelPath ?? book.orderedTracks.first?.fileRelPath ?? ""
        let tierRaw = tier.rawValue
        let ctx = modelContext
        let p = player

        pollingTask = Task {
            // Poll up to ~30 s (300 × 100 ms) for the rendition to land.
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                // selectTrimmedSource is @MainActor because ModelContext is not Sendable —
                // call it synchronously here on the main actor.
                let found = AudiobookPlayer.selectTrimmedSource(
                    bookID: bookID, relPath: relPath, tier: tierRaw, context: ctx)
                if found != nil {
                    isPreparing = false
                    preparingTier = nil
                    p.applyCadenceChange()
                    return
                }
            }
            // Timed out: clear Preparing state gracefully (original keeps playing).
            isPreparing = false
            preparingTier = nil
        }
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
