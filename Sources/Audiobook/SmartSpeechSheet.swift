import SwiftUI
import SwiftData
import SmartSpeechKit

/// "SmartSpeech" — the player's speed + silence-trimming controls in one sheet (the dock's gauge
/// button opens it). Playback speed drives `player.rate`; the trim toggle + tier drive this book's
/// `resolvedSmartSpeech` and reload the live engine via `applySmartSpeechChange()` — no batch render.
struct SmartSpeechSheet: View {
    let book: Audiobook
    let player: AudiobookPlayer

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private let minRate: Float = 0.8, maxRate: Float = 3.0

    private var trimOn: Bool { if case .on = book.resolvedSmartSpeech { return true }; return false }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    speedCard
                    trimCard
                }
                .padding(20)
                .tint(DS.Palette.Reclaim.mint)
            }
            .background(LinearGradient(colors: [DS.Palette.Reclaim.bg1, DS.Palette.Reclaim.bg2],
                                       startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .navigationTitle("SmartSpeech")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(DS.Palette.Reclaim.bg1, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(DS.Palette.Reclaim.mint)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }

    // MARK: Speed

    private var speedCard: some View {
        card {
            HStack(alignment: .firstTextBaseline) {
                Text("Playback speed").font(BrandFont.display(16, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.text)
                Spacer()
                Text(rateLabel(player.rate))
                    .font(ReceiptFont.mono(18, .bold))
                    .foregroundStyle(DS.Palette.Reclaim.mint)
            }
            HStack(spacing: 10) {
                stepButton("minus") { setRate(player.rate - 0.05) }
                Slider(
                    value: Binding(get: { Double(player.rate) }, set: { setRate(Float($0)) }),
                    in: Double(minRate)...Double(maxRate), step: 0.05
                )
                .tint(DS.Palette.Reclaim.mint)
                stepButton("plus") { setRate(player.rate + 0.05) }
            }
            HStack {
                Text(rateLabel(minRate)).font(ReceiptFont.mono(11)).foregroundStyle(DS.Palette.Reclaim.muted)
                Spacer()
                Text("1×").font(ReceiptFont.mono(11)).foregroundStyle(DS.Palette.Reclaim.muted)
                Spacer()
                Text(rateLabel(maxRate)).font(ReceiptFont.mono(11)).foregroundStyle(DS.Palette.Reclaim.muted)
            }
        }
    }

    /// Fine ±0.05 nudge buttons flanking the slider, for precise adjustment.
    private func stepButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Palette.Reclaim.text)
                .frame(width: 28, height: 28)
                .background(DS.Palette.Reclaim.fill, in: Circle())
        }
    }

    private func setRate(_ r: Float) {
        player.rate = (min(max(r, minRate), maxRate) * 20).rounded() / 20   // snap to 0.05
    }
    private func rateLabel(_ r: Float) -> String {
        r == r.rounded() ? "\(Int(r))×" : String(format: "%g×", r)
    }

    // MARK: Trim silence

    private var trimCard: some View {
        card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Trim silence").font(BrandFont.display(16, .bold))
                        .foregroundStyle(DS.Palette.Reclaim.text)
                    Text("LIVE · RECLAIMS TIME").font(ReceiptFont.mono(10)).kerning(1)
                        .foregroundStyle(DS.Palette.Reclaim.muted)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { trimOn }, set: { setTrim($0) })).labelsHidden()
                    .tint(DS.Palette.Reclaim.mint)
            }
            MintSegmented(labels: SmartSpeechSettings.Preset.allCases.map(\.displayName),
                          selected: trimOn ? SmartSpeechSettings.Preset.allCases.firstIndex(of: book.effectiveSmartSpeechTier) : nil,
                          disabled: !trimOn) { i in
                setTier(SmartSpeechSettings.Preset.allCases[i])
            }
        }
    }

    private func setTrim(_ on: Bool) {
        book.smartSpeechTier = on ? book.effectiveSmartSpeechTier.rawValue : smartSpeechOffValue
        try? modelContext.save()
        player.applySmartSpeechChange()
    }
    private func setTier(_ preset: SmartSpeechSettings.Preset) {
        book.smartSpeechTier = preset.rawValue
        try? modelContext.save()
        player.applySmartSpeechChange()
    }

    // MARK: Chrome

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .background(DS.Palette.Reclaim.fill, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(DS.Palette.Reclaim.stroke))
    }
}

/// A compact mint segmented control matching the "Reclaimed" look (system `.segmented` can't be
/// tinted to spec). Highlights `selected`; calls `onSelect` with the tapped index.
struct MintSegmented: View {
    let labels: [String]
    var selected: Int?
    var disabled: Bool = false
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(labels.indices, id: \.self) { i in
                Button { onSelect(i) } label: {
                    Text(labels[i])
                        .font(BrandFont.display(12, .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .foregroundStyle(i == selected ? DS.Palette.Reclaim.onMint : DS.Palette.Reclaim.muted)
                        .background(i == selected ? DS.Palette.Reclaim.mint : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.Palette.Reclaim.fill, in: RoundedRectangle(cornerRadius: 11))
        .opacity(disabled ? 0.5 : 1)
        .disabled(disabled)
    }
}
