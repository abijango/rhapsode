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
    /// Per-tier projected savings for this book (summed across its rendered files). Refreshed on
    /// appear and whenever a (re-)render lands (`isPreparing` → false).
    @State private var savings: CadenceProjectedSavings?
    /// Live render progress (0...1) from the coordinator while this book is being prepared.
    @State private var renderProgress: Double?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(selection: choiceBinding) {
                        tierRow(useGlobalLabel, savedText: nil).tag(Choice.useGlobal)
                        tierRow("Off", savedText: nil).tag(Choice.off)
                        ForEach(CadenceSettings.Preset.allCases, id: \.self) { preset in
                            tierRow(preset.displayName, savedText: savedText(for: preset)).tag(Choice.preset(preset))
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                    .disabled(isPreparing)
                } header: {
                    Text("For This Audiobook")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(footerText)
                        if savings?.hasData == true {
                            Text("Projected from this book’s silences.")
                        } else if case .on = book.resolvedCadence {
                            // No per-tier breakdown yet. Distinguish "rendered before this existed"
                            // (has a rendition, just no projections) from "not prepared yet".
                            if (savings?.originalDuration ?? 0) > 0 {
                                Text("Switch tiers once to calculate per-tier savings.")
                            } else {
                                Text("Per-tier savings appear once this book is prepared.")
                            }
                        }
                    }
                }

                if isPreparing {
                    Section {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            HStack(spacing: 8) {
                                if renderProgress == nil { ProgressView() }
                                Text(preparingLabel).font(.callout).foregroundStyle(.secondary)
                            }
                            if let progress = renderProgress, progress > 0 {
                                LinearProgressBar(fraction: progress, height: 6)
                            }
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
            .task {
                refreshSavings()
                // Cadence is on for this book but nothing has been rendered yet: make sure a
                // render is running (kick one if idle) and show live progress, rather than a
                // silent empty state. A no-op once a rendition with projections exists.
                if savings?.hasData != true, case .on(let tier) = book.resolvedCadence {
                    if await !CadenceRenderCoordinator.shared.isWorking(on: book.id) {
                        await CadenceRenderCoordinator.shared.enqueue(bookID: book.id)
                    }
                    startPreparingPoll(for: tier)
                }
            }
            // A (re-)render landing flips isPreparing back to false — pull the fresh projections.
            .onChange(of: isPreparing) { _, preparing in if !preparing { refreshSavings() } }
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
            while !Task.isCancelled {
                // Swap the live player onto the trimmed source as soon as it's playable.
                if AudiobookPlayer.selectTrimmedSource(bookID: bookID, relPath: relPath,
                                                       tier: tierRaw, context: ctx) != nil {
                    p.applyCadenceChange()
                }
                refreshSavings()
                renderProgress = await CadenceRenderCoordinator.shared.renderProgress(for: bookID)
                if savings?.hasData == true { isPreparing = false; renderProgress = nil; return }
                // Keep the spinner only while the render is actually queued/in-flight. If it
                // stops with no projections (failed / DRM), drop it so the footer hint shows.
                if await !CadenceRenderCoordinator.shared.isWorking(on: bookID) {
                    isPreparing = false
                    renderProgress = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// "Preparing… 42%" once a fraction is known, otherwise the indeterminate label.
    private var preparingLabel: String {
        if let progress = renderProgress, progress > 0 {
            return "Preparing… \(Int((progress * 100).rounded()))%"
        }
        return "Preparing…"
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        renderProgress = nil
    }

    // MARK: - Per-tier savings

    /// A picker row: tier name on the left, projected reduction on the right (when known).
    private func tierRow(_ name: String, savedText: String?) -> some View {
        HStack {
            Text(name)
            if let savedText {
                Spacer()
                Text(savedText).foregroundStyle(.secondary)
            }
        }
    }

    /// "47m shorter" for a tier with a known projection; nil when there is no data or it rounds
    /// to nothing (so the row stays clean rather than showing "0m").
    private func savedText(for preset: CadenceSettings.Preset) -> String? {
        guard let savings, savings.hasData else { return nil }
        let seconds = savings.saved(for: preset)
        guard seconds >= 30 else { return nil }
        return "\(Self.compactDuration(seconds)) shorter"
    }

    private func refreshSavings() {
        savings = Audiobook.projectedSavings(forBookID: book.id, context: modelContext)
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
