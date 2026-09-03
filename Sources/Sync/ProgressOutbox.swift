import Foundation

/// Dirty progress keys that failed to reach Dropbox. Flushed on reconnect, launch,
/// and Settings → Push now.
struct ProgressOutbox: Codable, Equatable, Sendable {
    var audiobookKeys: Set<String> = []
    var bookKeys: Set<String> = []
    var lifetimeStats = false
    var collectionsAudiobooks = false
    var collectionsBooks = false

    var isEmpty: Bool {
        audiobookKeys.isEmpty
            && bookKeys.isEmpty
            && !lifetimeStats
            && !collectionsAudiobooks
            && !collectionsBooks
    }

    var pendingCount: Int {
        audiobookKeys.count
            + bookKeys.count
            + (lifetimeStats ? 1 : 0)
            + (collectionsAudiobooks ? 1 : 0)
            + (collectionsBooks ? 1 : 0)
    }

    mutating func insertAudiobook(_ key: String) { audiobookKeys.insert(key) }
    mutating func insertBook(_ key: String) { bookKeys.insert(key) }
    mutating func insertLifetimeStats() { lifetimeStats = true }
    mutating func insertCollections(kind: FolderKind) {
        switch kind {
        case .audiobooks: collectionsAudiobooks = true
        case .books: collectionsBooks = true
        }
    }
}

enum ProgressOutboxStore {
    private static let key = "rhapsode.progress.outbox.v1"

    static func load() -> ProgressOutbox {
        guard let data = UserDefaults.standard.data(forKey: key),
              let box = try? JSONDecoder().decode(ProgressOutbox.self, from: data) else {
            return ProgressOutbox()
        }
        return box
    }

    static func save(_ box: ProgressOutbox) {
        if let data = try? JSONEncoder().encode(box) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum ProgressImportState {
    private static let nasKey = "rhapsode.progress.import.nas.v1"

    static var nasV1Done: Bool {
        get { UserDefaults.standard.bool(forKey: nasKey) }
        set { UserDefaults.standard.set(newValue, forKey: nasKey) }
    }
}
