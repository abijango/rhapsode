import Foundation

/// Progress + SmartSpeech stats over rhapsode-server.
///
/// Keys are container-relative paths (`Audiobooks/{itemId}/file.m4b`). The server
/// item id is the second path component.
actor RhapsodeServerProgressSync: ProgressSync {
    private let client: RhapsodeServerClient

    init(client: RhapsodeServerClient = RhapsodeServerClient()) {
        self.client = client
    }

    func push(_ progress: PlaybackProgress) async throws {
        guard let itemId = RhapsodeServerSource.itemId(fromLocalRelPath: progress.key) else {
            return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let updated = iso.string(from: progress.updatedAt)

        switch progress.kind {
        case .audiobooks:
            // Map track index + offset → absolute source seconds for the server.
            // Without track list we store offset only when index is 0; full mapping
            // uses lastOffsetSeconds as best-effort absolute when single-file M4B.
            let pos = progress.lastOffsetSeconds
            try await client.putProgress(
                itemId: itemId,
                body: .init(
                    updatedAt: updated,
                    audioPositionSeconds: pos,
                    audioDurationSeconds: nil,
                    ebookProgression: nil,
                    ebookLocatorJSON: nil,
                    isFinished: nil
                )
            )
            if let saved = progress.savedSeconds, let listened = progress.listenedSeconds {
                try await client.putItemStats(
                    itemId: itemId,
                    body: .init(
                        savedSeconds: saved,
                        listenedSeconds: listened,
                        readingSeconds: nil
                    )
                )
            } else if let saved = progress.savedSeconds {
                try await client.putItemStats(
                    itemId: itemId,
                    body: .init(savedSeconds: saved, listenedSeconds: nil, readingSeconds: nil)
                )
            } else if let listened = progress.listenedSeconds {
                try await client.putItemStats(
                    itemId: itemId,
                    body: .init(savedSeconds: nil, listenedSeconds: listened, readingSeconds: nil)
                )
            }
        case .books:
            var progression: Double?
            if let json = progress.readingLocatorJSON,
               let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let locations = obj["locations"] as? [String: Any],
               let total = locations["totalProgression"] as? Double {
                progression = total
            }
            try await client.putProgress(
                itemId: itemId,
                body: .init(
                    updatedAt: updated,
                    audioPositionSeconds: nil,
                    audioDurationSeconds: nil,
                    ebookProgression: progression,
                    ebookLocatorJSON: progress.readingLocatorJSON,
                    isFinished: nil
                )
            )
            if let reading = progress.readingSeconds {
                try await client.putItemStats(
                    itemId: itemId,
                    body: .init(savedSeconds: nil, listenedSeconds: nil, readingSeconds: reading)
                )
            }
        }
    }

    func pullAll() async throws -> [PlaybackProgress] {
        let rows = try await client.pullAllProgress()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        var out: [PlaybackProgress] = []
        for row in rows {
            let updated = iso.date(from: row.dto.updatedAt)
                ?? isoBasic.date(from: row.dto.updatedAt)
                ?? Date.distantPast

            // We don't know kind from progress alone — emit both candidate keys if needed.
            // Prefer audio if position set, else ebook.
            if let pos = row.dto.audioPositionSeconds {
                // Key must match local sourcePath. Without filename we use a scan of local library
                // later; store synthetic key prefix the merge can match via itemId helper.
                let key = "Audiobooks/\(row.itemId)/_server"
                var p = PlaybackProgress(
                    key: key,
                    kind: .audiobooks,
                    lastTrackIndex: 0,
                    lastOffsetSeconds: pos,
                    readingLocatorJSON: nil,
                    updatedAt: updated
                )
                if let stats = try? await client.getItemStats(itemId: row.itemId) {
                    p.listenedSeconds = stats.listenedSeconds
                    p.savedSeconds = stats.savedSeconds
                }
                out.append(p)
            }
            if row.dto.ebookLocatorJSON != nil || row.dto.ebookProgression != nil {
                let key = "Books/\(row.itemId)/_server"
                var p = PlaybackProgress(
                    key: key,
                    kind: .books,
                    lastTrackIndex: 0,
                    lastOffsetSeconds: 0,
                    readingLocatorJSON: row.dto.ebookLocatorJSON,
                    updatedAt: updated
                )
                if let stats = try? await client.getItemStats(itemId: row.itemId) {
                    p.readingSeconds = stats.readingSeconds
                }
                out.append(p)
            }
        }
        return out
    }

    func pushStats(_ stats: SmartSpeechStatsRecord) async throws {
        try await client.putLifetime(
            body: .init(savedSeconds: stats.savedSeconds, playedSeconds: stats.playedSeconds)
        )
    }

    func pullStats() async throws -> SmartSpeechStatsRecord? {
        let (saved, played, updatedAt) = try await client.getLifetime()
        return SmartSpeechStatsRecord(
            savedSeconds: saved,
            playedSeconds: played,
            updatedAt: updatedAt
        )
    }

    func pushCollections(_ manifest: CollectionsManifest) async throws {
        // Not on server v1
    }

    func pullCollections(kind: FolderKind) async throws -> CollectionsManifest? {
        nil
    }
}
