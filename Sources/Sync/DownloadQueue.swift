import Foundation

/// One row in the Downloads UI — either a single file or a collapsed MP3-folder group.
struct DownloadQueueRow: Identifiable {
    let id: String
    let title: String
    let kind: FolderKind
    let items: [DownloadItem]
    let isGroup: Bool

    var state: DownloadState {
        if items.contains(where: { $0.state == .failed }) { return .failed }
        if items.contains(where: { $0.state == .downloading }) { return .downloading }
        if items.contains(where: { $0.state == .pending }) { return .pending }
        if items.allSatisfy({ $0.state == .done }) { return .done }
        return .pending
    }

    var bytesReceived: Int64 { items.reduce(0) { $0 + $1.bytesReceived } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.totalBytes } }
    var filesDone: Int { items.filter { $0.state == .done }.count }
    var filesTotal: Int { items.count }

    var isActive: Bool { state == .pending || state == .downloading }
}

/// Collapses raw `DownloadItem` rows into user-facing queue rows and section buckets.
enum DownloadQueueGrouper {
    static func rows(from items: [DownloadItem]) -> [DownloadQueueRow] {
        var singles: [DownloadItem] = []
        var groups: [String: [DownloadItem]] = [:]

        for item in items {
            if let gid = item.groupID {
                groups[gid, default: []].append(item)
            } else {
                singles.append(item)
            }
        }

        var result: [DownloadQueueRow] = singles.map { single($0) }
        for (gid, members) in groups {
            result.append(group(id: gid, members: members))
        }
        return result.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Rows that need attention in Settings badge / shelf banner.
    static func attentionCount(from items: [DownloadItem]) -> Int {
        rows(from: items).filter { $0.state != .done }.count
    }

    static func active(from rows: [DownloadQueueRow]) -> [DownloadQueueRow] {
        rows.filter(\.isActive)
    }

    static func failed(from rows: [DownloadQueueRow]) -> [DownloadQueueRow] {
        rows.filter { $0.state == .failed }
    }

    private static func single(_ item: DownloadItem) -> DownloadQueueRow {
        DownloadQueueRow(
            id: item.id.uuidString,
            title: displayTitle(for: item),
            kind: item.kind,
            items: [item],
            isGroup: false
        )
    }

    private static func group(id: String, members: [DownloadItem]) -> DownloadQueueRow {
        let sorted = members.sorted {
            ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
        }
        let title = sorted.first?.groupFolderRelPath?
            .split(separator: "/").last.map(String.init)
            ?? sorted.first?.title
            ?? "Audiobook"
        return DownloadQueueRow(
            id: id,
            title: title,
            kind: sorted.first?.kind ?? .audiobooks,
            items: sorted,
            isGroup: true
        )
    }

    private static func displayTitle(for item: DownloadItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return item.remoteEntryID.split(separator: "/").last.map(String.init) ?? item.remoteEntryID
    }
}