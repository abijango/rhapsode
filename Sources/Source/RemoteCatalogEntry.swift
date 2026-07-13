import Foundation

/// One item from a remote library catalogue (rhapsode-server), not yet necessarily
/// downloaded. Used to show greyed-out shelf tiles and drive selective download.
struct RemoteCatalogEntry: Identifiable, Sendable, Hashable {
    /// Stable id: typically `itemId:fileId` from the server.
    let id: String
    let kind: FolderKind
    let title: String
    let author: String?
    /// Remote path for `downloadRequest` (`/Audiobooks/{itemId}/{fileId}`).
    let remotePath: String
    /// Container-relative path after import (`Audiobooks/{itemId}/file.m4b`).
    let localRelPath: String
    let sizeBytes: Int64
    /// Server library item id (progress + on-device matching).
    let serverItemId: String?
    /// File leaf name (for RemoteEntry.name construction).
    let fileName: String

    /// Build a `RemoteEntry` for the existing download / import pipeline.
    func asRemoteEntry() -> RemoteEntry {
        // SyncManager.relPath uses entry.name under Audiobooks/ or Books/.
        // localRelPath is "Audiobooks/{itemId}/file" → name must be "{itemId}/file".
        let name: String
        if localRelPath.hasPrefix("Audiobooks/") {
            name = String(localRelPath.dropFirst("Audiobooks/".count))
        } else if localRelPath.hasPrefix("Books/") {
            name = String(localRelPath.dropFirst("Books/".count))
        } else {
            name = fileName
        }
        return RemoteEntry(
            id: id,
            name: name,
            path: remotePath,
            size: sizeBytes,
            isFolder: false,
            contentHash: serverItemId
        )
    }
}
