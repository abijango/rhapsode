import Foundation

/// One item in a remote library folder. `path` is relative to the source's root
/// (for Dropbox App-folder access that means e.g. "/Audiobooks/foo.m4b" — the
/// Dropbox namespace makes app-folder paths look root-relative).
struct RemoteEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let size: Int64
    let isFolder: Bool

    init(id: String, name: String, path: String, size: Int64, isFolder: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.isFolder = isFolder
    }
}

/// Abstraction over a remote library backend. The download/watch pipeline (Phase 2)
/// sits *above* this boundary and never knows the concrete backend, so Dropbox is
/// swappable later. MVP ships one conformer (`DropboxSource`); `MockLibrarySource`
/// exists so the audiobook/e-book domains can develop without real OAuth.
///
/// Conformers must be safe to use across Swift Concurrency tasks (be an `actor`,
/// or an immutable `Sendable` type).
protocol LibrarySource: Sendable {
    /// Establish (or refresh) authentication. Throws if the user must connect.
    func authenticate() async throws

    /// List the immediate children of `path` (root-relative).
    func listFolder(_ path: String) async throws -> [RemoteEntry]

    /// Delta changes since `cursor` (nil = from the beginning). Returns the new
    /// entries plus the cursor to persist for the next call.
    func changes(since cursor: String?) async throws -> (entries: [RemoteEntry], cursor: String)

    /// Block until the server reports changes for `cursor`. `true` = changes pending.
    func longpoll(cursor: String) async throws -> Bool

    /// Download `entry` to `destination` (an absolute file URL inside the container).
    /// For a folder entry, the folder's contents are copied recursively.
    func download(_ entry: RemoteEntry, to destination: URL) async throws

    /// Create `path` if it does not already exist (idempotent).
    func ensureFolderExists(_ path: String) async throws

    /// A cursor representing the folder's current state, for watching changes
    /// from this point forward (without listing existing entries).
    func latestCursor(_ path: String) async throws -> String
}

/// Errors common to any `LibrarySource`.
enum LibrarySourceError: Error, Sendable, LocalizedError {
    case notAuthenticated
    case notFound(path: String)
    case network(underlying: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not connected to Dropbox."
        case .notFound(let path): "Not found: \(path)"
        case .network(let underlying): "Network error: \(underlying)"
        case .decoding(let detail): "Couldn’t read response: \(detail)"
        }
    }
}
