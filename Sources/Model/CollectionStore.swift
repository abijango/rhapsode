import Foundation
import SwiftData

/// CRUD + membership for user-defined `LibraryCollection`s. Changes stamp
/// `CollectionsSyncState` so `SyncManager` can push cross-device manifests to
/// `/.rhapsode-sync/collections-{audiobooks,books}.json` (LWW by `updatedAt`).
@MainActor
final class CollectionStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Fetch

    func collections(kind: FolderKind) throws -> [LibraryCollection] {
        let all = try context.fetch(FetchDescriptor<LibraryCollection>(
            sortBy: [SortDescriptor(\.name, comparator: .localizedStandard)])
        )
        return all.filter { $0.kind == kind }
    }

    // MARK: Mutate

    @discardableResult
    func create(name: String, kind: FolderKind) throws -> LibraryCollection {
        let trimmed = Self.normalizedName(name)
        guard !trimmed.isEmpty else { throw CollectionError.emptyName }
        guard try !nameExists(trimmed, kind: kind) else { throw CollectionError.duplicateName }
        let collection = LibraryCollection(name: trimmed, kind: kind)
        context.insert(collection)
        try save(kind: kind)
        return collection
    }

    func rename(_ collection: LibraryCollection, to name: String) throws {
        let trimmed = Self.normalizedName(name)
        guard !trimmed.isEmpty else { throw CollectionError.emptyName }
        let others = try collections(kind: collection.kind).filter { $0.id != collection.id }
        if others.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw CollectionError.duplicateName
        }
        collection.name = trimmed
        try save(collection: collection)
    }

    func delete(_ collection: LibraryCollection) throws {
        let kind = collection.kind
        context.delete(collection)
        try save(kind: kind)
    }

    func toggleMembership(collection: LibraryCollection, audiobook: Audiobook) throws {
        guard collection.kind == .audiobooks else { return }
        if let idx = audiobook.collections.firstIndex(where: { $0.id == collection.id }) {
            audiobook.collections.remove(at: idx)
        } else {
            audiobook.collections.append(collection)
        }
        try save(collection: collection)
    }

    func toggleMembership(collection: LibraryCollection, book: Book) throws {
        guard collection.kind == .books else { return }
        if let idx = book.collections.firstIndex(where: { $0.id == collection.id }) {
            book.collections.remove(at: idx)
        } else {
            book.collections.append(collection)
        }
        try save(collection: collection)
    }

    func isMember(_ collection: LibraryCollection, audiobook: Audiobook) -> Bool {
        audiobook.collections.contains { $0.id == collection.id }
    }

    func isMember(_ collection: LibraryCollection, book: Book) -> Bool {
        book.collections.contains { $0.id == collection.id }
    }

    // MARK: Helpers

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nameExists(_ name: String, kind: FolderKind) throws -> Bool {
        try collections(kind: kind).contains {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func save(kind: FolderKind) throws {
        guard context.hasChanges else { return }
        try context.save()
        CollectionsSyncState.touch(kind)
    }

    private func save(collection: LibraryCollection) throws {
        try save(kind: collection.kind)
    }
}

enum CollectionError: LocalizedError {
    case emptyName
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .emptyName: "Collection name can't be empty."
        case .duplicateName: "A collection with that name already exists."
        }
    }
}