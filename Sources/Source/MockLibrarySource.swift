import Foundation

/// A `LibrarySource` backed by sample fixtures bundled in the app
/// (`SampleLibrary/Audiobooks` and `SampleLibrary/Books`). It lets the audiobook
/// and e-book domains run the full loop — list → download → import → render —
/// without real Dropbox/OAuth. `download` copies a fixture into the container.
///
/// Fixture layout (folder reference bundled via project.yml):
///   SampleLibrary/Audiobooks/<file>.m4b
///   SampleLibrary/Audiobooks/<AudiobookName>/   (folder of MP3s)
///   SampleLibrary/Books/<file>.epub
final class MockLibrarySource: LibrarySource, Sendable {
    /// Root of the bundled fixtures, e.g. `.../Rhapsode.app/SampleLibrary`.
    private let fixturesRoot: URL?

    /// Map of source root path ("/Audiobooks", "/Books") → bundle subdirectory.
    private static let folderMap: [String: String] = [
        "/Audiobooks": "Audiobooks",
        "/Books": "Books",
    ]

    init(fixturesRoot: URL? = Bundle.main.url(forResource: "SampleLibrary", withExtension: nil)) {
        self.fixturesRoot = fixturesRoot
    }

    func authenticate() async throws {
        // Always "authenticated" for the mock.
    }

    func ensureFolderExists(_ path: String) async throws {
        // Fixtures are bundled; nothing to create.
    }

    func latestCursor(_ path: String) async throws -> String { "mock-cursor" }

    func listFolder(_ path: String) async throws -> [RemoteEntry] {
        guard let fixturesRoot, let sub = Self.folderMap[path] else { return [] }
        let dir = fixturesRoot.appendingPathComponent(sub, isDirectory: true)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }

        return names.sorted().compactMap { name in
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64 ?? 0
            return RemoteEntry(
                id: "\(path)/\(name)",
                name: name,
                path: "\(path)/\(name)",
                size: size,
                isFolder: isDir.boolValue
            )
        }
    }

    func changes(since cursor: String?) async throws -> (entries: [RemoteEntry], cursor: String) {
        // The mock returns the full listing of both roots once; cursor is static.
        var all: [RemoteEntry] = []
        for root in Self.folderMap.keys.sorted() {
            all += try await listFolder(root)
        }
        return (all, "mock-cursor")
    }

    func longpoll(cursor: String) async throws -> Bool {
        // No live changes in the mock.
        false
    }

    func download(_ entry: RemoteEntry, to destination: URL) async throws {
        guard let fixturesRoot else { throw LibrarySourceError.notFound(path: entry.path) }
        // Reconstruct the bundle URL from the entry path ("/Audiobooks/Name" → sub/Name).
        let components = entry.path.split(separator: "/").map(String.init)
        guard let first = components.first, let sub = Self.folderMap["/\(first)"] else {
            throw LibrarySourceError.notFound(path: entry.path)
        }
        let rest = components.dropFirst()
        var source = fixturesRoot.appendingPathComponent(sub, isDirectory: true)
        for part in rest { source = source.appendingPathComponent(part) }

        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw LibrarySourceError.notFound(path: entry.path)
        }
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}
