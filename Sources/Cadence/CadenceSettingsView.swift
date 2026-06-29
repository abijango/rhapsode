import SwiftUI
import CadenceKit

/// Per-book Cadence override (spec §9, §5.4). A single menu sets how Cadence behaves for **this**
/// audiobook, independent of the global setting:
///   • Use Default → inherit the global on/off + default tier (`cadenceTier = nil`)
///   • Off → silence-trimming off for this book, even when globally on (`"off"`)
///   • Default / More / Aggressive → force that profile for this book, even when globally off
///
/// Changing the choice persists it, (re-)renders if it resolves to ON (showing "Preparing…" until
/// the rendition for the new tier is ready, then swapping seamlessly via `applyCadenceChange()`),
/// or reverts to the original immediately if it resolves to OFF. The global master switch and the
/// default sensitivity live in Settings → Cadence, not here.
struct CadenceSettingsView: View {
    let book: Audiobook
    /// The live player — used to swap the audio source on a change via `applyCadenceChange()`.
    let player: AudiobookPlayer

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// The five selectable states, mapped to/from `Audiobook.cadenceTier`.
    enum Choice: Hashable {
        case useGlobal
        case off
        case preset(CadenceSettings.Preset)
    }

    @State private var isPreparing = false
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: choiceBinding) {
                        Text(useGlobalLabel).tag(Choice.useGlobal)
                        Text("Off").tag(Choice.off)
                        ForEach(CadenceSettings.Preset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(Choice.preset(preset))
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .disabled(isPreparing)
                } header: {
                    Text("For This Audiobook")
                } footer: {
                    Text(footerText)
                }

                if isPreparing {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Preparing…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }

                if let saved = book.cadenceSavedSeconds, saved > 0 {
                    Section {
                        LabeledContent("Saved in this book", value: Self.compactDuration(saved))
                    }
                }
            }
            .navigationTitle(CadenceBranding.featureName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onDisappear { cancelPolling() }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Choice ↔ cadenceTier

    private var choiceBinding: Binding<Choice> {
        Binding(get: { currentChoice }, set: { apply($0) })
    }

    private var currentChoice: Choice {
        switch book.cadenceTier {
        case nil: return .useGlobal
        case cadenceOffValue: return .off
        case let raw?:
            return CadenceSettings.Preset(rawValue: raw).map(Choice.preset) ?? .useGlobal
        }
    }

    /// "Use Default (More)" / "Use Default (Off)" — shows what inheriting global resolves to now.
    private var useGlobalLabel: String {
        CadencePreferences.isEnabled
            ? "Use Default (\(CadencePreferences.defaultTier.displayName))"
            : "Use Default (Off)"
    }

    private var footerText: String {
        switch book.resolvedCadence {
        case .off:
            return "Silence-trimming is off for this audiobook."
        case .on(let preset):
            switch preset {
            case .default: return "Fast, natural narrators sound best on Default — subtle compression you may not notice."
            case .more: return "More compression for slower narrators; keeps clarity while improving pace."
            case .aggressive: return "Maximum compression; best for very slow or deliberate narration."
            }
        }
    }

    // MARK: - Apply a change

    private func apply(_ choice: Choice) {
        guard choice != currentChoice else { return }
        switch choice {
        case .useGlobal:     book.cadenceTier = nil
        case .off:           book.cadenceTier = cadenceOffValue
        case .preset(let p): book.cadenceTier = p.rawValue
        }
        try? modelContext.save()

        let bookID = book.id
        switch book.resolvedCadence {
        case .on(let preset):
            // (Re-)render for the resolved tier, then swap seamlessly when it's ready.
            Task {
                await CadenceRenderCoordinator.shared.cancel(bookID: bookID)
                await CadenceRenderCoordinator.shared.enqueue(bookID: bookID)
            }
            startPreparingPoll(for: preset)
        case .off:
            // Revert to the original at the current mapped position, immediately.
            cancelPolling()
            isPreparing = false
            player.applyCadenceChange()
        }
    }

    // MARK: - Preparing poll

    private func startPreparingPoll(for tier: CadenceSettings.Preset) {
        cancelPolling()
        isPreparing = true
        let bookID = book.id
        let relPath = player.currentTrack?.fileRelPath ?? book.orderedTracks.first?.fileRelPath ?? ""
        let tierRaw = tier.rawValue
        let ctx = modelContext
        let p = player
        pollingTask = Task {
            // Poll up to ~30 s for the rendition for the chosen tier to land.
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                if AudiobookPlayer.selectTrimmedSource(bookID: bookID, relPath: relPath,
                                                       tier: tierRaw, context: ctx) != nil {
                    isPreparing = false
                    p.applyCadenceChange()
                    return
                }
            }
            isPreparing = false   // timed out; original keeps playing
        }
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Compact per-book duration, e.g. "1h 3m", "12m", "<1m".
    private static func compactDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "<1m" }
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60, minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }
}
