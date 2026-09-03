import AMSMB2
import Foundation
import UIKit

/// Task-local so nested SMB calls (catalog → listFolder) reuse the same exclusive
/// section instead of deadlocking. Separate SwiftUI `.task`s do not inherit this.
private enum SmbLibraryIOLock {
    @TaskLocal static var held = false
}

/// `LibrarySource` over an SMB2/3 share (Synology / Windows NAS).
///
/// Paths in `listFolder` match Dropbox-style roots (`/Audiobooks`, `/Books`) and
/// are mapped onto `SmbConfig.audiobooksPath` / `booksPath` under the share.
actor SmbLibrarySource: LibrarySource {
    private var manager: SMB2Manager?
    private var ioBusy = false
    private var ioWaiters: [CheckedContinuation<Void, Never>] = []

    func authenticate() async throws {
        _ = try await withExclusiveClient { $0 }
    }

    /// Connect and return a short diagnostic string for Settings "Test".
    func testConnection() async throws -> String {
        manager = nil
        let client = try await connectedManager()
        let audioPath = SmbConfig.audiobooksPath
        let booksPath = SmbConfig.booksPath
        var parts: [String] = ["OK — share “\(SmbConfig.share)”"]
        do {
            let n = try await client.contentsOfDirectory(atPath: audioPath, recursive: false).count
            parts.append("Audiobooks “\(audioPath)”: \(n) item(s)")
        } catch {
            parts.append("Audiobooks “\(audioPath)”: not found (pick the folder)")
        }
        do {
            let n = try await client.contentsOfDirectory(atPath: booksPath, recursive: false).count
            parts.append("Books “\(booksPath)”: \(n) item(s)")
        } catch {
            parts.append("Books “\(booksPath)”: not found (pick the folder)")
        }
        return parts.joined(separator: " · ")
    }

    /// List share names on the server (helps when the share field is wrong).
    func listShareNames() async throws -> [String] {
        manager = nil
        let mgr = try makeManager()
        do {
            let shares = try await mgr.listShares(enumerateHidden: false)
            return shares.map(\.name).sorted()
        } catch {
            throw Self.mapError(error, context: "Could not list shares on \(SmbConfig.host)")
        }
    }

    /// Directories only, paths relative to the **current share root** (for folder pickers).
    /// Pass `""` for the share root.
    func listSubdirectories(atShareRelativePath path: String) async throws -> [String] {
        let smbPath = SmbConfig.normalizeRelPath(path)
        let files: [[URLResourceKey: Any]]
        do {
            files = try await withExclusiveClient {
                try await $0.contentsOfDirectory(atPath: smbPath, recursive: false)
            }
        } catch {
            throw Self.mapError(
                error,
                context: "List folders in “\(smbPath.isEmpty ? "(share root)" : smbPath)”")
        }
        var names: [String] = []
        for file in files {
            guard let name = file[.nameKey] as? String, !name.isEmpty, name != ".", name != ".." else {
                continue
            }
            if name.hasPrefix(".") { continue }
            let isDirectory: Bool = {
                if let flag = file[URLResourceKey.isDirectoryKey] as? Bool { return flag }
                if let t = file[.fileResourceTypeKey] as? URLFileResourceType {
                    return t == .directory
                }
                return false
            }()
            if isDirectory { names.append(name) }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Open the configured share only (no library folder check). Resets the session.
    func connectToConfiguredShare() async throws {
        manager = nil
        _ = try await connectedManager()
    }

    func listFolder(_ path: String) async throws -> [RemoteEntry] {
        let smbPath = Self.mapLibraryPath(path)
        let files: [[URLResourceKey: Any]]
        do {
            files = try await withExclusiveClient {
                try await $0.contentsOfDirectory(atPath: smbPath, recursive: false)
            }
        } catch {
            throw Self.mapError(error, context: "List “\(smbPath)”")
        }
        var entries: [RemoteEntry] = []
        for file in files {
            guard let name = file[.nameKey] as? String, !name.isEmpty, name != ".", name != ".." else {
                continue
            }
            if name.hasPrefix(".") { continue }
            let isDirectory: Bool = {
                if let flag = file[URLResourceKey.isDirectoryKey] as? Bool { return flag }
                if let t = file[.fileResourceTypeKey] as? URLFileResourceType {
                    return t == .directory
                }
                return false
            }()
            let size = (file[.fileSizeKey] as? Int64)
                ?? (file[.fileSizeKey] as? Int).map(Int64.init)
                ?? 0
            let childPath = smbPath.isEmpty ? name : "\(smbPath)/\(name)"
            let remotePath = Self.toDropboxStylePath(childPath)
            entries.append(RemoteEntry(
                id: remotePath,
                name: name,
                path: remotePath,
                size: size,
                isFolder: isDirectory,
                contentHash: nil
            ))
        }
        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func changes(since cursor: String?) async throws -> (entries: [RemoteEntry], cursor: String) {
        let audio = try await listFolder(DropboxConfig.audiobooksPath)
        let books = try await listFolder(DropboxConfig.booksPath)
        let stamp = ISO8601DateFormatter().string(from: Date())
        return (audio + books, stamp)
    }

    func longpoll(cursor: String) async throws -> Bool {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return !Task.isCancelled
    }

    func download(_ entry: RemoteEntry, to destination: URL) async throws {
        let smbPath = Self.mapLibraryPath(entry.path)
        try await withExclusiveClient { client in
            if entry.isFolder {
                try await self.downloadFolder(client: client, smbPath: smbPath, to: destination)
                return
            }
            try await self.streamDownload(client: client, smbPath: smbPath, to: destination)
        }
    }

    /// Small-file write for progress / stats JSON under the share (e.g. `rhapsode-sync/…`).
    ///
    /// AMSMB2’s plain `write` uses `O_CREAT|O_EXCL` (create only if missing) →
    /// collision on update. Strategy:
    /// 1. Ensure parent dir exists.
    /// 2. Write a **unique non-dot temp** (O_EXCL always OK).
    /// 3. Remove dest + move temp → dest.
    /// 4. If move fails after dest was removed: recreate dest with `write` from
    ///    in-memory bytes (do **not** use `append(offset:0)` — that truncates first
    ///    and throws ENOENT when the file is gone, which was wiping progress JSON).
    func writeFile(_ data: Data, to path: String) async throws {
        let smbPath = Self.mapLibraryPath(path)
        try await withExclusiveClient { client in
            try await self.writeFileUnlocked(data, smbPath: smbPath, client: client)
        }
    }

    private func writeFileUnlocked(_ data: Data, smbPath: String, client: SMB2Manager) async throws {
        let parent = (smbPath as NSString).deletingLastPathComponent
        let leaf = (smbPath as NSString).lastPathComponent

        if !parent.isEmpty, parent != "." {
            var built = ""
            for part in parent.split(separator: "/") {
                built = built.isEmpty ? String(part) : "\(built)/\(part)"
                try? await client.createDirectory(atPath: built)
            }
        }

        // Non-hidden temp: some NAS setups treat leading-dot names specially.
        let tempPath: String = {
            let name = "\(leaf).\(UUID().uuidString).part"
            if parent.isEmpty || parent == "." { return name }
            return "\(parent)/\(name)"
        }()

        func cleanupTemp() async {
            try? await client.removeItem(atPath: tempPath)
        }

        // 1) Stage full payload under a unique name.
        do {
            try await client.write(data: data, toPath: tempPath, progress: nil)
        } catch {
            await cleanupTemp()
            throw Self.mapError(error, context: "Write temp “\(tempPath)”")
        }

        // 2) Swap into place (remove dest only after temp is known-good).
        try? await client.removeItem(atPath: smbPath)
        do {
            try await client.moveItem(atPath: tempPath, toPath: smbPath)
            return
        } catch {
            try? await client.removeItem(atPath: smbPath)
            do {
                try await client.moveItem(atPath: tempPath, toPath: smbPath)
                return
            } catch {
                // 3) Recreate dest from memory with O_EXCL create (dest is missing).
                //    Never append(offset:0) here — truncate-before-open → ENOENT wipe.
                await cleanupTemp()
                try? await client.removeItem(atPath: smbPath)
                do {
                    try await client.write(data: data, toPath: smbPath, progress: nil)
                    return
                } catch {
                    try? await client.removeItem(atPath: smbPath)
                    do {
                        try await client.write(data: data, toPath: smbPath, progress: nil)
                        return
                    } catch {
                        throw Self.mapError(error, context: "Write “\(smbPath)”")
                    }
                }
            }
        }
    }

    /// Small-file read for progress / stats JSON. Returns `nil` if missing.
    func readFile(at path: String) async throws -> Data? {
        let smbPath = Self.mapLibraryPath(path)
        do {
            return try await withExclusiveClient {
                try await $0.contents(atPath: smbPath)
            }
        } catch {
            // Missing path is common before the first push — treat as nil.
            let ns = error as NSError
            if ns.code == 2 { return nil } // ENOENT
            throw Self.mapError(error, context: "Read “\(smbPath)”")
        }
    }

    func ensureFolderExists(_ path: String) async throws {
        let smbPath = Self.mapLibraryPath(path)
        guard !smbPath.isEmpty else { return }
        try await withExclusiveClient { client in
            var built = ""
            for part in smbPath.split(separator: "/") {
                built = built.isEmpty ? String(part) : "\(built)/\(part)"
                do {
                    try await client.createDirectory(atPath: built)
                } catch {
                    // Exists is fine
                }
            }
        }
    }

    func latestCursor(_ path: String) async throws -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    // MARK: - Cover art (pre-download, for grey catalogue tiles)

    /// Best-effort cover bytes without downloading the full library item when possible.
    /// 1) Sidecar images next to the media file (`cover.jpg`, `folder.jpg`, …).
    /// 2) EPUBs: download file (≤80 MB), extract embedded cover, delete temp.
    /// 3) M4B/M4A/MP4: range-read top-level atoms, download only `moov`, pull `covr`.
    /// 4) MP3: range-read the ID3v2 prefix and parse `APIC`.
    func fetchCoverData(for entry: RemoteCatalogEntry) async throws -> Data? {
        let mediaSmb = Self.mapLibraryPath(entry.remotePath)
        return try await withExclusiveClient { client in
            try await self.fetchCoverDataUnlocked(for: entry, client: client, mediaSmb: mediaSmb)
        }
    }

    private func fetchCoverDataUnlocked(
        for entry: RemoteCatalogEntry,
        client: SMB2Manager,
        mediaSmb: String
    ) async throws -> Data? {
        if let sidecar = try await fetchSidecarCover(client: client, mediaSmbPath: mediaSmb) {
            return sidecar
        }
        let lower = entry.fileName.lowercased()
        if lower.hasSuffix(".epub") {
            if entry.sizeBytes > 80 * 1024 * 1024 { return nil }
            return try await fetchEPUBEmbeddedCover(client: client, mediaSmbPath: mediaSmb)
        }
        if lower.hasSuffix(".m4b") || lower.hasSuffix(".m4a") || lower.hasSuffix(".mp4") {
            return try await fetchMP4EmbeddedCover(
                client: client, mediaSmbPath: mediaSmb, sizeHint: entry.sizeBytes)
        }
        if lower.hasSuffix(".mp3") {
            return try await fetchMP3EmbeddedCover(client: client, mediaSmbPath: mediaSmb)
        }
        return nil
    }

    /// Walk MP4 atoms over SMB ranges; only the `moov` box is downloaded (not the audio).
    private func fetchMP4EmbeddedCover(
        client: SMB2Manager,
        mediaSmbPath: String,
        sizeHint: Int64
    ) async throws -> Data? {
        var fileSize = sizeHint
        if fileSize <= 0 {
            let attrs = try? await client.attributesOfItem(atPath: mediaSmbPath)
            fileSize = (attrs?[.fileSizeKey] as? Int64)
                ?? (attrs?[.fileSizeKey] as? Int).map(Int64.init)
                ?? 0
        }
        guard fileSize > 64 else { return nil }
        return try await EmbeddedCoverExtractor.coverFromMP4(fileSize: fileSize) { offset, count in
            let start = UInt64(offset)
            let end = UInt64(offset) + UInt64(count)
            return try await client.contents(atPath: mediaSmbPath, range: start..<end)
        }
    }

    private func fetchMP3EmbeddedCover(client: SMB2Manager, mediaSmbPath: String) async throws -> Data? {
        // ID3v2 lives at the start; 2 MB covers large tags with full-res APIC.
        let prefix = try await client.contents(atPath: mediaSmbPath, range: 0..<UInt64(2 * 1024 * 1024))
        return EmbeddedCoverExtractor.coverFromMP3Prefix(prefix)
    }

    private func fetchSidecarCover(client: SMB2Manager, mediaSmbPath: String) async throws -> Data? {
        let parent: String = {
            if let slash = mediaSmbPath.lastIndex(of: "/") {
                return String(mediaSmbPath[..<slash])
            }
            return ""
        }()
        let baseName = (mediaSmbPath as NSString).lastPathComponent
        let stem = (baseName as NSString).deletingPathExtension
        let candidates = [
            "cover.jpg", "cover.jpeg", "cover.png",
            "folder.jpg", "folder.jpeg", "folder.png",
            "\(stem).jpg", "\(stem).jpeg", "\(stem).png",
            "Cover.jpg", "cover.JPG",
        ]
        for name in candidates {
            let path = parent.isEmpty ? name : "\(parent)/\(name)"
            do {
                let data = try await client.contents(atPath: path)
                if data.count > 100, UIImage(data: data) != nil { return data }
            } catch {
                continue
            }
        }
        // Also scan parent directory for any small image that looks like a cover.
        do {
            let kids = try await client.contentsOfDirectory(atPath: parent, recursive: false)
            for file in kids {
                guard let name = file[.nameKey] as? String else { continue }
                let lower = name.lowercased()
                guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") else {
                    continue
                }
                if lower.contains("cover") || lower.contains("folder") || lower == "cover.jpg" {
                    let path = parent.isEmpty ? name : "\(parent)/\(name)"
                    if let data = try? await client.contents(atPath: path),
                       data.count > 100, data.count < 8 * 1024 * 1024,
                       UIImage(data: data) != nil {
                        return data
                    }
                }
            }
        } catch {
            // Parent unreadable — ignore.
        }
        return nil
    }

    private func fetchEPUBEmbeddedCover(client: SMB2Manager, mediaSmbPath: String) async throws -> Data? {
        let data = try await client.contents(atPath: mediaSmbPath)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rhapsode-cover-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try data.write(to: tmp, options: .atomic)
        return await EbookImporter.coverJPEGData(fromLocalEPUB: tmp)
    }

    // MARK: - Catalogue helpers (selective download)

    func listCatalog() async throws -> [RemoteCatalogEntry] {
        try await withExclusiveClient { _ in
            try await self.listCatalogUnlocked()
        }
    }

    private func listCatalogUnlocked() async throws -> [RemoteCatalogEntry] {
        try await authenticate()
        var out: [RemoteCatalogEntry] = []
        for (kind, root) in [
            (FolderKind.audiobooks, DropboxConfig.audiobooksPath),
            (FolderKind.books, DropboxConfig.booksPath),
        ] {
            let entries = try await listFolderRecursiveFiles(root: root)
            for e in entries {
                let lower = e.name.lowercased()
                switch kind {
                case .audiobooks:
                    guard lower.hasSuffix(".m4b") || lower.hasSuffix(".mp3") else { continue }
                case .books:
                    guard lower.hasSuffix(".epub") else { continue }
                }
                let localRel: String = {
                    let p = e.path.hasPrefix("/") ? String(e.path.dropFirst()) : e.path
                    return p
                }()
                let title = (e.name as NSString).deletingPathExtension
                out.append(RemoteCatalogEntry(
                    id: e.id,
                    kind: kind,
                    title: title.isEmpty ? e.name : title,
                    author: nil,
                    remotePath: e.path,
                    localRelPath: localRel,
                    sizeBytes: e.size,
                    serverItemId: nil,
                    fileName: e.name
                ))
            }
        }
        return out
    }

    // MARK: - Internals

    /// AMSMB2’s queue is concurrent and libsmb2 is not safe for overlapping I/O.
    /// Cover fetches + downloads on a cached session were dropping the TCP
    /// connection (`ENOTCONN` / “SMB2 server not connected.”).
    private func withExclusiveClient<T>(
        _ body: (SMB2Manager) async throws -> T
    ) async throws -> T {
        if SmbLibraryIOLock.held {
            return try await performWithReconnect(body)
        }
        await beginExclusiveIO()
        defer { endExclusiveIO() }
        return try await SmbLibraryIOLock.$held.withValue(true) {
            try await self.performWithReconnect(body)
        }
    }

    private func performWithReconnect<T>(
        _ body: (SMB2Manager) async throws -> T
    ) async throws -> T {
        do {
            return try await body(try await connectedManager())
        } catch {
            guard Self.isDisconnected(error) else { throw error }
            manager = nil
            return try await body(try await connectedManager())
        }
    }

    private func beginExclusiveIO() async {
        if ioBusy {
            await withCheckedContinuation { continuation in
                ioWaiters.append(continuation)
            }
            return
        }
        ioBusy = true
    }

    private func endExclusiveIO() {
        if ioWaiters.isEmpty {
            ioBusy = false
        } else {
            ioWaiters.removeFirst().resume()
        }
    }

    /// True for a dead SMB session (`ENOTCONN` / code 57), including after `mapError`.
    nonisolated static func isDisconnected(_ error: Error) -> Bool {
        if let source = error as? LibrarySourceError, case .network(let detail) = source {
            return detail.contains("[code 57]")
                || detail.localizedCaseInsensitiveContains("not connected")
        }
        let ns = error as NSError
        return ns.domain == NSPOSIXErrorDomain && ns.code == Int(POSIXErrorCode.ENOTCONN.rawValue)
    }

    private func connectedManager() async throws -> SMB2Manager {
        if let manager {
            do {
                try await connectConfiguredShare(manager)
                return manager
            } catch {
                self.manager = nil
            }
        }
        let mgr = try makeManager()
        try await connectConfiguredShare(mgr)
        manager = mgr
        return mgr
    }

    /// `connectShare` echoes and reconnects when the NAS dropped an idle session.
    private func connectConfiguredShare(_ mgr: SMB2Manager) async throws {
        let share = SmbConfig.share
        guard !share.isEmpty else {
            throw LibrarySourceError.network(underlying: "SMB share name is empty.")
        }
        do {
            try await mgr.connectShare(name: share, encrypted: false)
        } catch {
            // Some Synology setups require SMB3 encryption; retry once.
            do {
                try await mgr.connectShare(name: share, encrypted: true)
            } catch let second {
                // Login often already works (listShares succeeds) — code 1 on
                // connectShare usually means the share name does not exist.
                var context = "Could not open share “\(share)” on \(SmbConfig.host)"
                if let names = try? await mgr.listShares(enumerateHidden: false).map(\.name),
                   !names.isEmpty,
                   !names.contains(where: { $0.caseInsensitiveCompare(share) == .orderedSame }) {
                    let preview = names.prefix(8).joined(separator: ", ")
                    context += ". That share name is not on this NAS (found: \(preview)\(names.count > 8 ? ", …" : "")). Use one of the listed names — e.g. Storage if books live under /volume1/Storage/."
                }
                throw Self.mapError(second, context: context)
            }
        }
    }

    private func makeManager() throws -> SMB2Manager {
        guard let url = SmbConfig.serverURL else {
            throw LibrarySourceError.network(underlying: "SMB host is empty. Use e.g. 192.168.8.200")
        }
        guard let profile = SmbConfig.activeProfile else {
            throw LibrarySourceError.network(underlying: "No SMB storage selected.")
        }
        let password = (try? SmbKeychain(profileId: profile.id).loadPassword()) ?? ""
        if password.isEmpty && profile.username.isEmpty {
            throw LibrarySourceError.network(
                underlying: "Enter a NAS username and password (guest rarely works on Synology).")
        }
        let credential = URLCredential(
            user: profile.credentialUser,
            password: password,
            persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else {
            throw LibrarySourceError.network(underlying: "Could not create SMB client for \(url.absoluteString)")
        }
        // Default 60s is tight for a large M4B over Tailscale / a slow NAS.
        mgr.timeout = 180
        return mgr
    }

    /// Connect using an explicit profile (folder picker / save-test for non-active profiles).
    func connect(profile: SmbStorageProfile, password: String?) async throws {
        manager = nil
        guard let url = profile.serverURL else {
            throw LibrarySourceError.network(underlying: "Server is empty.")
        }
        guard !profile.share.isEmpty else {
            throw LibrarySourceError.network(underlying: "Share is empty — pick one under Available Shares.")
        }
        let pass = password
            ?? (try? SmbKeychain(profileId: profile.id).loadPassword())
            ?? ""
        let credential = URLCredential(
            user: profile.credentialUser,
            password: pass,
            persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else {
            throw LibrarySourceError.network(underlying: "Could not create SMB client.")
        }
        mgr.timeout = 180
        do {
            try await mgr.connectShare(name: profile.share, encrypted: false)
        } catch {
            do {
                try await mgr.connectShare(name: profile.share, encrypted: true)
            } catch let second {
                throw Self.mapError(
                    second,
                    context: "Could not open share “\(profile.share)” on \(profile.host)")
            }
        }
        manager = mgr
    }

    func listShareNames(profile: SmbStorageProfile, password: String?) async throws -> [String] {
        manager = nil
        guard let url = profile.serverURL else {
            throw LibrarySourceError.network(underlying: "Server is empty.")
        }
        let pass = password
            ?? (try? SmbKeychain(profileId: profile.id).loadPassword())
            ?? ""
        let credential = URLCredential(
            user: profile.credentialUser,
            password: pass,
            persistence: .forSession)
        guard let mgr = SMB2Manager(url: url, credential: credential) else {
            throw LibrarySourceError.network(underlying: "Could not create SMB client.")
        }
        do {
            let shares = try await mgr.listShares(enumerateHidden: false)
            return shares.map(\.name).sorted()
        } catch {
            throw Self.mapError(error, context: "Could not list shares on \(profile.host)")
        }
    }

    func listSubdirectories(profile: SmbStorageProfile, password: String?, at path: String) async throws -> [String] {
        try await connect(profile: profile, password: password)
        return try await listSubdirectories(atShareRelativePath: path)
    }

    func testConnection(profile: SmbStorageProfile, password: String?) async throws -> String {
        try await connect(profile: profile, password: password)
        let client = try await connectedManager()
        var parts: [String] = ["OK — “\(profile.name)” · share “\(profile.share)”"]
        do {
            let n = try await client.contentsOfDirectory(atPath: profile.audiobooksPath, recursive: false).count
            parts.append("Audiobooks: \(n)")
        } catch {
            parts.append("Audiobooks path missing — pick folder")
        }
        do {
            let n = try await client.contentsOfDirectory(atPath: profile.booksPath, recursive: false).count
            parts.append("Books: \(n)")
        } catch {
            parts.append("Books path missing — pick folder")
        }
        return parts.joined(separator: " · ")
    }

    private func downloadFolder(client: SMB2Manager, smbPath: String, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let children = try await client.contentsOfDirectory(atPath: smbPath, recursive: false)
        for file in children {
            guard let name = file[.nameKey] as? String, !name.hasPrefix(".") else { continue }
            let childSmb = smbPath.isEmpty ? name : "\(smbPath)/\(name)"
            let isDirectory: Bool = {
                if let flag = file[URLResourceKey.isDirectoryKey] as? Bool { return flag }
                if let t = file[.fileResourceTypeKey] as? URLFileResourceType {
                    return t == .directory
                }
                return false
            }()
            let dest = destination.appendingPathComponent(name)
            if isDirectory {
                try await downloadFolder(client: client, smbPath: childSmb, to: dest)
            } else {
                try await streamDownload(client: client, smbPath: childSmb, to: dest)
            }
        }
    }

    /// Stream a remote SMB file to a local URL (AMSMB2 writes incrementally; no full-file `Data`).
    private func streamDownload(
        client: SMB2Manager,
        smbPath: String,
        to destination: URL,
        progress: SMB2Manager.ReadProgressHandler = nil
    ) async throws {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try await client.downloadItem(atPath: smbPath, to: destination, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw Self.mapError(error, context: "Download “\(smbPath)”")
        }
    }

    private func listFolderRecursiveFiles(root: String) async throws -> [RemoteEntry] {
        var result: [RemoteEntry] = []
        var stack = [root]
        while let path = stack.popLast() {
            let kids = try await listFolder(path)
            for k in kids {
                if k.isFolder {
                    stack.append(k.path)
                } else {
                    result.append(k)
                }
            }
        }
        return result
    }

    nonisolated static func mapLibraryPath(_ dropboxStyle: String) -> String {
        var p = dropboxStyle
        if p.hasPrefix("/") { p = String(p.dropFirst()) }
        let lower = p.lowercased()
        if lower == "audiobooks" || lower.hasPrefix("audiobooks/") {
            let rest = p.dropFirst(min(p.count, "Audiobooks".count))
            let suffix = rest.hasPrefix("/") ? String(rest.dropFirst()) : String(rest)
            let base = SmbConfig.audiobooksPath
            return suffix.isEmpty ? base : "\(base)/\(suffix)"
        }
        if lower == "books" || lower.hasPrefix("books/") {
            let rest = p.dropFirst(min(p.count, "Books".count))
            let suffix = rest.hasPrefix("/") ? String(rest.dropFirst()) : String(rest)
            let base = SmbConfig.booksPath
            return suffix.isEmpty ? base : "\(base)/\(suffix)"
        }
        return SmbConfig.normalizeRelPath(p)
    }

    nonisolated static func toDropboxStylePath(_ smbPath: String) -> String {
        let p = SmbConfig.normalizeRelPath(smbPath)
        let audio = SmbConfig.audiobooksPath
        let books = SmbConfig.booksPath
        if p == audio || p.hasPrefix(audio + "/") {
            let rest = p == audio ? "" : String(p.dropFirst(audio.count))
            return "/Audiobooks" + rest
        }
        if p == books || p.hasPrefix(books + "/") {
            let rest = p == books ? "" : String(p.dropFirst(books.count))
            return "/Books" + rest
        }
        return "/" + p
    }

    /// Turn opaque POSIX/libsmb2 errors into actionable copy.
    nonisolated static func mapError(_ error: Error, context: String) -> LibrarySourceError {
        let ns = error as NSError
        let code = ns.code
        let posixHint: String = {
            // Darwin: 1 = EPERM, 2 = ENOENT, 13 = EACCES, 57 = ENOTCONN, 60 = ETIMEDOUT, 61 = ECONNREFUSED
            switch code {
            case 1, 13:
                return "Permission or login failed. Check username/password, and that the user can access the share. On Synology, use the DSM account name (leave Domain empty unless you use AD)."
            case 2:
                return "Path or share not found. Share name is the short share (e.g. “Rhapsode”), not a full volume path. Folder paths are relative to that share (e.g. Audiobooks)."
            case 57:
                return "The NAS dropped the SMB session. Stay on the same Wi‑Fi or Tailscale and tap Retry — large audiobooks often succeed on the second try."
            case 60, 51:
                return "Timed out. Confirm LAN/Tailscale can reach the host and SMB is enabled."
            case 61, 111:
                return "Connection refused. Is SMB enabled on the NAS? Try host IP (192.168.x.x)."
            case 65:
                return "No route to host. Join the same Wi‑Fi or turn on Tailscale."
            default:
                return ns.localizedDescription
            }
        }()
        let detail = "\(context). \(posixHint) [code \(code)]"
        return LibrarySourceError.network(underlying: detail)
    }
}
