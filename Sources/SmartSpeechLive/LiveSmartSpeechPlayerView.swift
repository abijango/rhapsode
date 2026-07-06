#if DEBUG
import SwiftUI
import SwiftData
import SmartSpeechKit

/// EXPLORATION MODULE — DEBUG-only screen to drive the live (on-the-fly) SmartSpeech engine against a
/// real downloaded book. Isolated from the shipped player; reachable only from a DEBUG entry in
/// Settings. Pairs the subjective by-ear test with an objective, live silence-removed readout.
struct LiveSmartSpeechPlayerView: View {
    @Query(sort: \Audiobook.title) private var books: [Audiobook]
    @State private var engine = LiveSmartSpeechEngine()
    @State private var selectedBookID: UUID?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var exportStatus: String?
    @State private var exporting = false

    var body: some View {
        Form {
            bookPicker
            if engine.isLoaded {
                meterSection
                transportSection
                trimSection
                diagnosticsSection
            }
        }
        .navigationTitle("Live SmartSpeech (spike)")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { engine.teardown() }
    }

    // MARK: Book picker

    private var bookPicker: some View {
        Section("Book") {
            if books.isEmpty {
                Text("No downloaded audiobooks. Sync one first.").foregroundStyle(.secondary)
            }
            ForEach(books) { book in
                Button {
                    selectedBookID = book.id
                    engine.load(book: book)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(book.title).foregroundStyle(.primary)
                            if let author = book.author {
                                Text(author).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if selectedBookID == book.id { Image(systemName: "checkmark") }
                    }
                }
            }
        }
    }

    // MARK: Meter (quantified confirmation)

    private var meterSection: some View {
        Section("Silence removed") {
            LiveTrimMeter(removedSoFar: engine.removedSoFar,
                          removedPercent: engine.removedSoFarPercent,
                          projectedTotal: engine.projectedTotalSaved,
                          sourceDuration: engine.sourceDuration)
            if let regions = engine.prescanRegionCount {
                LabeledContent("Regions (pre-scan)", value: "\(regions)")
            }
            if engine.isMultiFile {
                Text("Multi-file book — spike plays the first file only.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Transport

    private var transportSection: some View {
        Section("Transport") {
            VStack(spacing: 8) {
                Slider(value: scrubBinding, in: 0...max(engine.sourceDuration, 1)) { editing in
                    scrubbing = editing
                    if !editing { engine.seek(toSource: scrubValue) }
                }
                HStack {
                    Text(timeString(displayPosition)).font(.caption.monospacedDigit())
                    Spacer()
                    Text("−\(timeString(engine.sourceDuration - displayPosition))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button { engine.skip(-15) } label: { Image(systemName: "gobackward.15") }
                Spacer()
                Button {
                    engine.isPlaying ? engine.pause() : engine.play()
                } label: {
                    Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                Spacer()
                Button { engine.skip(30) } label: { Image(systemName: "goforward.30") }
            }
            .buttonStyle(.plain)
            .font(.title2)
        }
    }

    // MARK: Trim controls

    private var trimSection: some View {
        Section("Trim") {
            Toggle("Trim silences (live)", isOn: Binding(
                get: { engine.trimEnabled },
                set: { engine.applyTrim(enabled: $0, preset: engine.preset) }))
            Picker("Tier", selection: Binding(
                get: { engine.preset },
                set: { engine.applyTrim(enabled: engine.trimEnabled, preset: $0) })) {
                ForEach(SmartSpeechSettings.Preset.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
            Picker("Speed", selection: Binding(
                get: { engine.rate },
                set: { engine.setRate($0) })) {
                ForEach([Float(1.0), 1.25, 1.5, 2.0, 3.0], id: \.self) { r in
                    Text(String(format: "%.2g×", r)).tag(r)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Status", value: engine.status)
            LabeledContent("Buffered ahead", value: String(format: "%.1f s", engine.bufferedAheadSeconds))
            LabeledContent("Source position", value: timeString(engine.sourcePosition))
            LabeledContent("Detect floor (global)",
                           value: engine.detectionFloorDb.map { String(format: "%.1f dB", $0) } ?? "…")
            LabeledContent("Silence ceiling (live)", value: String(format: "%.0f dB", LiveSmartSpeechTuning.silenceCeilingDb))
            Button {
                exportTrimmed()
            } label: {
                if exporting { ProgressView() } else { Text("Export live-trimmed .m4a (oracle A/B)") }
            }
            .disabled(exporting || selectedBook == nil)
            if let exportStatus {
                Text(exportStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var selectedBook: Audiobook? {
        books.first { $0.id == selectedBookID }
    }

    private func exportTrimmed() {
        guard let book = selectedBook, let src = LiveSmartSpeechSource(book: book) else { return }
        exporting = true
        exportStatus = "Exporting…"
        Task.detached(priority: .userInitiated) {
            do {
                let outURL = try LiveSmartSpeechExport.exportTrimmed(url: src.url, preset: src.preset)
                await MainActor.run {
                    exporting = false
                    exportStatus = "Wrote \(outURL.lastPathComponent) to Documents."
                }
            } catch {
                await MainActor.run {
                    exporting = false
                    exportStatus = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Helpers

    private var displayPosition: TimeInterval { scrubbing ? scrubValue : engine.sourcePosition }

    private var scrubBinding: Binding<Double> {
        Binding(get: { scrubbing ? scrubValue : engine.sourcePosition },
                set: { scrubValue = $0 })
    }

    private func timeString(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// The quantified-confirmation surface: live removed-so-far + projected total + a proportion bar.
private struct LiveTrimMeter: View {
    let removedSoFar: TimeInterval
    let removedPercent: Double
    let projectedTotal: TimeInterval?
    let sourceDuration: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(durationString(removedSoFar)).font(.title2.bold().monospacedDigit())
                Text("removed so far").foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f%%", removedPercent * 100))
                    .font(.headline.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.tint)
                        .frame(width: geo.size.width * min(1, max(0, removedPercent)))
                }
            }
            .frame(height: 8)
            if let projected = projectedTotal {
                Text("Projected total for this book: ~\(durationString(projected)) (\(percentString(projected)))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Pre-scanning…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func percentString(_ saved: TimeInterval) -> String {
        guard sourceDuration > 0 else { return "0%" }
        return String(format: "%.0f%%", saved / sourceDuration * 100)
    }

    private func durationString(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let m = total / 60, s = total % 60
        if m >= 60 { return String(format: "%dh %dm", m / 60, m % 60) }
        return m > 0 ? String(format: "%dm %02ds", m, s) : String(format: "%ds", s)
    }
}
#endif
