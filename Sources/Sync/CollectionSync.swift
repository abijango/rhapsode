import Foundation

/// One collection in the cross-device wire manifest. `memberKeys` are stable
/// container-relative paths (`Audiobook.sourcePath` / `Book.fileRelPath`).
struct CollectionWire: Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var memberKeys: [String]
}

/// Per-shelf collections manifest backed up to the Dropbox app folder. One file
/// per `FolderKind`, last-writer-wins on `updatedAt` (same trade-off as stats).
struct CollectionsManifest: Codable, Sendable, Equatable {
    var kind: FolderKind
    var collections: [CollectionWire]
    var updatedAt: Date

    func isNewer(than local: Date?) -> Bool {
        guard let local else { return true }
        return updatedAt > local
    }
}

/// Local change stamp per shelf kind, driving LWW push/pull decisions.
enum CollectionsSyncState {
    private static let audiobooksKey = "collectionsSync.updatedAt.audiobooks"
    private static let booksKey = "collectionsSync.updatedAt.books"

    static func updatedAt(for kind: FolderKind) -> Date? {
        let raw = UserDefaults.standard.double(forKey: key(for: kind))
        guard raw > 0 else { return nil }
        return Date(timeIntervalSinceReferenceDate: raw)
    }

    static func setUpdatedAt(_ date: Date, for kind: FolderKind) {
        UserDefaults.standard.set(date.timeIntervalSinceReferenceDate, forKey: key(for: kind))
    }

    static func touch(_ kind: FolderKind) {
        setUpdatedAt(Date(), for: kind)
    }

    private static func key(for kind: FolderKind) -> String {
        switch kind {
        case .audiobooks: audiobooksKey
        case .books: booksKey
        }
    }
}