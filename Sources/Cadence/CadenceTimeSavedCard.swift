import SwiftUI

/// Time Saved stat card for Cadence (silence-trimming) feature.
///
/// A rounded card displaying the cumulative time saved across all audiobooks
/// with Cadence enabled. Shows an empty state when no time has been saved yet,
/// and displays the total and book count when savings are available.
///
/// Layout:
/// - Rounded card with secondary system grouped background.
/// - Header: clock.badge.checkmark icon + "TIME SAVED" caption (uppercase, semibold).
/// - Empty state: helper text "Start listening with Cadence on to see your saved time."
/// - Populated state: large bold duration (e.g. "4h 12m") + subtitle with book count.
/// A reusable Cadence stat card (icon + uppercase title + big value + optional subtitle, on a
/// rounded grouped-background card). Two of these sit side by side in Settings (Time Saved +
/// Render Time); the big value shrinks to fit the narrower half-width layout.
struct CadenceStatCard: View {
    let icon: String
    let title: String
    /// Large value string (e.g. "4h 12m"). Ignored when `isEmpty`.
    let value: String
    var subtitle: String? = nil
    /// Shown in place of `value` when there's nothing to report yet.
    var emptyText: String? = nil
    var isEmpty: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            if isEmpty, let emptyText {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(value)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(DS.Spacing.lg)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct CadenceTimeSavedCard: View {
    /// Total seconds saved across all audiobooks.
    let totalSeconds: TimeInterval
    /// Number of audiobooks contributing to the savings.
    let bookCount: Int

    var body: some View {
        CadenceStatCard(
            icon: "clock.badge.checkmark",
            title: "TIME SAVED",
            value: compactDuration(totalSeconds),
            subtitle: bookCount > 0 ? "across \(bookCount) audiobook\(bookCount == 1 ? "" : "s")" : nil,
            emptyText: "Start listening with \(CadenceBranding.featureName) on to see your saved time.",
            isEmpty: totalSeconds <= 0)
    }

    // MARK: - Helpers

    /// Format seconds into a compact duration string.
    /// Examples: "4h 12m", "12m", "<1m"
    private func compactDuration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "<1m" }

        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "<1m"
        }
    }
}

// MARK: - Preview

#Preview("Populated") {
    VStack(spacing: 20) {
        CadenceTimeSavedCard(totalSeconds: 15120, bookCount: 3)
        CadenceTimeSavedCard(totalSeconds: 780, bookCount: 1)
        CadenceTimeSavedCard(totalSeconds: 45, bookCount: 2)
    }
    .padding()
}

#Preview("Empty") {
    CadenceTimeSavedCard(totalSeconds: 0, bookCount: 0)
        .padding()
}
