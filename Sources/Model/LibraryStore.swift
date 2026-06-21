import Foundation
import SwiftData

/// Thin repository over a SwiftData `ModelContext`.
///
/// Deliberately minimal: container/context wiring plus a few accessors the UI and
/// later phases share. Not a full abstraction layer — call the `ModelContext`
/// directly for anything not covered here.
@MainActor
final class LibraryStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: Fetch

    func audiobooks() throws -> [Audiobook] {
        try context.fetch(
            FetchDescriptor<Audiobook>(sortBy: [SortDescriptor(\.title)])
        )
    }

    func books() throws -> [Book] {
        try context.fetch(
            FetchDescriptor<Book>(sortBy: [SortDescriptor(\.title)])
        )
    }

    func watchedFolders() throws -> [WatchedFolder] {
        try context.fetch(FetchDescriptor<WatchedFolder>())
    }

    func downloads() throws -> [DownloadItem] {
        try context.fetch(FetchDescriptor<DownloadItem>())
    }

    // MARK: Mutate

    func insert(_ model: any PersistentModel) {
        context.insert(model)
    }

    func delete(_ model: any PersistentModel) {
        context.delete(model)
    }

    func save() throws {
        guard context.hasChanges else { return }
        try context.save()
    }

    // MARK: Delete library items (removes the local file(s) too)

    func deleteAudiobook(_ audiobook: Audiobook) {
        Self.removeContainerItem(audiobook.sourcePath)
        audiobook.coverPath.map(Self.removeContainerItem)
        context.delete(audiobook)
        try? save()
    }

    func deleteBook(_ book: Book) {
        Self.removeContainerItem(book.fileRelPath)
        book.coverPath.map(Self.removeContainerItem)
        context.delete(book)
        try? save()
    }

    /// Remove a file or folder at a container-relative path (best-effort).
    private static func removeContainerItem(_ relativePath: String) {
        guard let url = try? ContainerPaths.url(forRelativePath: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
