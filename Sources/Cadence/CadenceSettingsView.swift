import SwiftUI
import CadenceKit

/// Per-book Cadence (silence-trimming) control panel. Spec §9, §5.4.
///
/// Allows the user to enable/disable the feature globally and select the per-book
/// trimming sensitivity (Default / More / Aggressive). Helper text guides the choice:
/// fast natural narrators → Default; slow/deliberate → More/Aggressive.
///
/// **Note:** This is a view shell; presentation and integration into PlayerView is deferred to WP9.
struct CadenceSettingsView: View {
    let book: Audiobook
    @Environment(\.modelContext) private var modelContext

    @State private var enabled = false

    var body: some View {
        Form {
            Section("Cadence") {
                Toggle("Enable \(CadenceBranding.featureName)", isOn: Binding(
                    get: { enabled },
                    set: { new in
                        enabled = new
                        CadencePreferences.isEnabled = new
                    }
                ))

                if enabled {
                    Picker(
                        "Trimming Sensitivity",
                        selection: Binding(
                            get: { book.effectiveCadenceTier },
                            set: { book.cadenceTier = $0.rawValue }
                        )
                    ) {
                        ForEach(CadenceSettings.Preset.allCases, id: \.self) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(helperText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        if CadenceStats.totalSavedSeconds > 0 {
                            Text(CadenceStats.formattedTotal())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Preparing…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            enabled = CadencePreferences.isEnabled
        }
        .onChange(of: enabled) { _, new in
            CadencePreferences.isEnabled = new
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
}
