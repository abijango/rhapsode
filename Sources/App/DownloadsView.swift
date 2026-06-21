import SwiftData
import SwiftUI

/// Visible download queue. Backed by `DownloadItem`; updates live as the
/// `SyncManager` moves items through pending → downloading → done / failed.
struct DownloadsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \DownloadItem.remoteEntryID) private var items: [DownloadItem]

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Files pulled from Dropbox appear here while they transfer.")
                )
            } else {
                List {
                    ForEach(items) { item in
                        DownloadRow(item: item)
                    }
                    if items.contains(where: { $0.state == .done || $0.state == .failed }) {
                        Button("Clear finished", role: .destructive) { clearFinished() }
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clearFinished() {
        for item in items where item.state == .done || item.state == .failed {
            modelContext.delete(item)
        }
        try? modelContext.save()
    }
}

private struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: DS.Spacing.md) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(item.kind == .audiobooks ? "Audiobook" : "E-book")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if item.state == .downloading { ProgressView() }
        }
    }

    private var name: String {
        if let title = item.title, !title.isEmpty { return title }
        return item.remoteEntryID.split(separator: "/").last.map(String.init) ?? item.remoteEntryID
    }

    private var icon: some View {
        Group {
            switch item.state {
            case .pending: Image(systemName: "clock")
            case .downloading: Image(systemName: "arrow.down.circle")
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }
}
