import Foundation

/// HTTP client for rhapsode-server (`/v1/*`).
actor RhapsodeServerClient {
    private let session: URLSession
    private let keychain = RhapsodeServerKeychain()
    /// Short-lived resolved base so we don't re-probe every request.
    private var resolvedBase: URL?

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Seconds to wait when probing home vs remote base URLs.
    /// The NAS Docker bridge can take several seconds even for a light `/health`
    /// (measured ~1–7s on LAN); keep this above that so home Wi‑Fi is usable.
    private static let probeTimeout: TimeInterval = 10

    // MARK: - Catalog types

    struct PrimaryFile: Decodable, Sendable, Identifiable {
        let id: String
        let role: String
        let name: String
        let sizeBytes: Int64?
        let sortOrder: Int

        enum CodingKeys: String, CodingKey {
            case id, role, name
            case sizeBytes = "size_bytes"
            case sortOrder = "sort_order"
        }

        init(id: String, role: String, name: String, sizeBytes: Int64?, sortOrder: Int) {
            self.id = id
            self.role = role
            self.name = name
            self.sizeBytes = sizeBytes
            self.sortOrder = sortOrder
        }
    }

    struct LibraryItem: Decodable, Sendable, Identifiable {
        let id: String
        let kind: String
        let title: String
        let author: String?
        let durationSeconds: Double?
        let missing: Bool
        let hasAudio: Bool
        let hasEbook: Bool
        let updatedAt: String
        /// Present when server returns a fat catalogue (no per-item files round-trip).
        let primaryFile: PrimaryFile?

        enum CodingKeys: String, CodingKey {
            case id, kind, title, author, missing
            case durationSeconds = "duration_seconds"
            case hasAudio = "has_audio"
            case hasEbook = "has_ebook"
            case updatedAt = "updated_at"
            case primaryFile = "primary_file"
        }
    }

    struct MediaFile: Decodable, Sendable, Identifiable {
        let id: String
        let role: String
        let name: String
        let sizeBytes: Int64?
        let sortOrder: Int

        enum CodingKeys: String, CodingKey {
            case id, role, name
            case sizeBytes = "size_bytes"
            case sortOrder = "sort_order"
        }
    }

    struct ProgressDTO: Codable, Sendable {
        var updatedAt: String
        var audioPositionSeconds: Double?
        var audioDurationSeconds: Double?
        var ebookProgression: Double?
        var ebookLocatorJSON: String?
        var isFinished: Bool?

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case audioPositionSeconds = "audio_position_seconds"
            case audioDurationSeconds = "audio_duration_seconds"
            case ebookProgression = "ebook_progression"
            case ebookLocatorJSON = "ebook_locator_json"
            case isFinished = "is_finished"
        }
    }

    struct ItemStatsDTO: Codable, Sendable {
        var savedSeconds: Double?
        var listenedSeconds: Double?
        var readingSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case savedSeconds = "saved_seconds"
            case listenedSeconds = "listened_seconds"
            case readingSeconds = "reading_seconds"
        }
    }

    struct LifetimeStatsDTO: Codable, Sendable {
        var savedSeconds: Double?
        var playedSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case savedSeconds = "saved_seconds"
            case playedSeconds = "played_seconds"
        }
    }

    struct MeResponse: Decodable, Sendable {
        let userId: String
        let deviceId: String
        let deviceName: String
        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case deviceId = "device_id"
            case deviceName = "device_name"
        }
    }

    struct TokenResponse: Decodable, Sendable {
        let userId: String
        let deviceId: String
        let apiToken: String
        let deviceName: String
        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
            case deviceId = "device_id"
            case apiToken = "api_token"
            case deviceName = "device_name"
        }
    }

    // MARK: - Base URL resolution (home LAN vs Tailscale)

    /// Pick a reachable base URL: tries home first (when set), then remote.
    /// Caches the winner for subsequent requests until a failure clears it.
    @discardableResult
    func resolveBaseURL(forceProbe: Bool = false) async throws -> URL {
        if !forceProbe, let resolvedBase {
            return resolvedBase
        }
        let candidates = RhapsodeServerConfig.candidateURLs
        guard !candidates.isEmpty else {
            throw LibrarySourceError.network(underlying: "Server URL not set")
        }
        var failures: [String] = []
        for base in candidates {
            do {
                try await probeHealth(base: base)
                resolvedBase = base
                RhapsodeServerConfig.rememberActiveBaseURL(base)
                return base
            } catch {
                let host = base.host.map { h in
                    base.port.map { "\(h):\($0)" } ?? h
                } ?? base.absoluteString
                failures.append("\(host): \(error.localizedDescription)")
            }
        }
        resolvedBase = nil
        RhapsodeServerConfig.clearActiveBaseURL()
        throw LibrarySourceError.network(
            underlying: "No server reachable. "
                + failures.joined(separator: " · "))
    }

    /// Human label for Settings status (which base is active).
    nonisolated static func endpointDescription(for url: URL?) -> String? {
        guard let u = url else { return nil }
        if let host = u.host {
            if let port = u.port { return "\(host):\(port)" }
            return host
        }
        return u.absoluteString
    }

    func activeEndpointDescription() -> String? {
        Self.endpointDescription(for: resolvedBase ?? RhapsodeServerConfig.activeBaseURL)
    }

    private func probeHealth(base: URL) async throws {
        // Prefer lightweight `/health` (no SQLite). `/v1/health` hits the DB and
        // can stall for many seconds while a library scan holds the connection lock.
        var req = URLRequest(url: base.appending(path: "/health"))
        req.httpMethod = "GET"
        req.timeoutInterval = Self.probeTimeout
        let (data, resp) = try await session.data(for: req)
        try throwIfNeeded(resp, data: data)
    }

    private func invalidateResolvedBase() {
        resolvedBase = nil
        RhapsodeServerConfig.clearActiveBaseURL()
    }

    // MARK: - Auth

    func hasCredentials() throws -> Bool {
        guard !RhapsodeServerConfig.candidateURLs.isEmpty else { return false }
        return try keychain.loadToken() != nil
    }

    /// Lightweight check that the stored bearer is accepted (`GET /v1/me`).
    func authenticate() async throws {
        guard !RhapsodeServerConfig.candidateURLs.isEmpty else {
            throw LibrarySourceError.notAuthenticated
        }
        guard try keychain.loadToken() != nil else {
            throw LibrarySourceError.notAuthenticated
        }
        _ = try await resolveBaseURL()
        _ = try await getJSON(path: "/v1/me", as: MeResponse.self)
    }

    func me() async throws -> MeResponse {
        try await getJSON(path: "/v1/me", as: MeResponse.self)
    }

    /// Persist a device API token (pasted from bootstrap / another device registration).
    func saveAPIToken(_ token: String) throws {
        try keychain.saveToken(token)
    }

    func clearAPIToken() throws {
        try keychain.clear()
    }

    private static var platformLabel: String {
        #if targetEnvironment(macCatalyst)
        "mac"
        #else
        "ios"
        #endif
    }

    /// First-device setup when the server has no users yet.
    func bootstrap(deviceName: String, bootstrapToken: String) async throws -> TokenResponse {
        let base = try await resolveBaseURL(forceProbe: true)
        var req = URLRequest(url: base.appending(path: "/v1/auth/bootstrap"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(bootstrapToken, forHTTPHeaderField: "X-Bootstrap-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_name": deviceName,
            "platform": Self.platformLabel,
        ])
        let (data, resp) = try await session.data(for: req)
        try throwIfNeeded(resp, data: data)
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        try keychain.saveToken(decoded.apiToken)
        return decoded
    }

    /// Register an additional device using an existing device's bearer token.
    /// The new token is stored locally (replacing the temporary parent token if that was used).
    func registerDevice(deviceName: String, parentToken: String) async throws -> TokenResponse {
        let base = try await resolveBaseURL(forceProbe: true)
        var req = URLRequest(url: base.appending(path: "/v1/auth/devices"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(parentToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "device_name": deviceName,
            "platform": Self.platformLabel,
        ])
        let (data, resp) = try await session.data(for: req)
        try throwIfNeeded(resp, data: data)
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        try keychain.saveToken(decoded.apiToken)
        return decoded
    }

    // MARK: - Library

    func listLibrary(kind: String? = nil) async throws -> [LibraryItem] {
        var path = "/v1/library"
        if let kind, !kind.isEmpty {
            path += "?kind=\(kind)"
        }
        struct Wrap: Decodable { let items: [LibraryItem] }
        return try await getJSON(path: path, as: Wrap.self).items
    }

    /// Trigger a server library index. `mode`: `"incremental"` (default) or `"full"`.
    func scanLibrary(mode: String = "incremental") async throws {
        struct Wrap: Decodable {
            let ok: Bool?
            let upserted: Int?
            let skippedUnchanged: Int?
            enum CodingKeys: String, CodingKey {
                case ok, upserted
                case skippedUnchanged = "skipped_unchanged"
            }
        }
        let path = "/v1/library/scan?mode=\(mode)"
        _ = try await postJSON(path: path, body: EmptyBody(), as: Wrap.self)
    }

    func listFiles(itemId: String) async throws -> [MediaFile] {
        struct Wrap: Decodable { let files: [MediaFile] }
        return try await getJSON(path: "/v1/items/\(itemId)/files", as: Wrap.self).files
    }

    /// Background download request. Uses the last known-good base (or first candidate).
    /// Call `resolveBaseURL()` first when possible so the active endpoint is current.
    nonisolated func downloadRequest(itemId: String, fileId: String) throws -> URLRequest {
        guard let base = RhapsodeServerConfig.baseURL else {
            throw LibrarySourceError.notAuthenticated
        }
        guard let token = try keychain.loadToken() else {
            throw LibrarySourceError.notAuthenticated
        }
        var req = URLRequest(url: base.appending(path: "/v1/items/\(itemId)/files/\(fileId)/download"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    func downloadFile(itemId: String, fileId: String, to destination: URL) async throws {
        _ = try await resolveBaseURL()
        let req = try downloadRequest(itemId: itemId, fileId: fileId)
        do {
            let (tmp, resp) = try await session.download(for: req)
            try throwIfNeeded(resp, data: nil)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tmp, to: destination)
        } catch {
            if Self.isLikelyConnectivityFailure(error) {
                invalidateResolvedBase()
                _ = try await resolveBaseURL(forceProbe: true)
                let retry = try downloadRequest(itemId: itemId, fileId: fileId)
                let (tmp, resp) = try await session.download(for: retry)
                try throwIfNeeded(resp, data: nil)
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: tmp, to: destination)
            } else {
                throw error
            }
        }
    }

    // MARK: - Progress / stats

    func getProgress(itemId: String) async throws -> ProgressDTO {
        try await getJSON(path: "/v1/items/\(itemId)/progress", as: ProgressDTO.self)
    }

    func putProgress(itemId: String, body: ProgressDTO) async throws {
        _ = try await putJSON(path: "/v1/items/\(itemId)/progress", body: body, as: ProgressDTO.self)
    }

    struct IdentifiableProgress: Sendable {
        let itemId: String
        let dto: ProgressDTO
    }

    func pullAllProgress() async throws -> [IdentifiableProgress] {
        struct Row: Decodable {
            let itemId: String
            let audioPositionSeconds: Double?
            let audioDurationSeconds: Double?
            let ebookProgression: Double?
            let ebookLocatorJSON: String?
            let isFinished: Bool
            let updatedAt: String
            enum CodingKeys: String, CodingKey {
                case itemId = "item_id"
                case audioPositionSeconds = "audio_position_seconds"
                case audioDurationSeconds = "audio_duration_seconds"
                case ebookProgression = "ebook_progression"
                case ebookLocatorJSON = "ebook_locator_json"
                case isFinished = "is_finished"
                case updatedAt = "updated_at"
            }
        }
        struct Wrap: Decodable { let items: [Row] }
        let rows = try await getJSON(path: "/v1/progress", as: Wrap.self).items
        return rows.map {
            IdentifiableProgress(
                itemId: $0.itemId,
                dto: ProgressDTO(
                    updatedAt: $0.updatedAt,
                    audioPositionSeconds: $0.audioPositionSeconds,
                    audioDurationSeconds: $0.audioDurationSeconds,
                    ebookProgression: $0.ebookProgression,
                    ebookLocatorJSON: $0.ebookLocatorJSON,
                    isFinished: $0.isFinished
                )
            )
        }
    }

    func putItemStats(itemId: String, body: ItemStatsDTO) async throws {
        var req = try await authorizedRequest(path: "/v1/items/\(itemId)/stats", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await performData(req)
        try throwIfNeeded(resp, data: data)
    }

    func getItemStats(itemId: String) async throws -> ItemStatsDTO {
        struct Full: Decodable {
            let savedSeconds: Double
            let listenedSeconds: Double
            let readingSeconds: Double
            enum CodingKeys: String, CodingKey {
                case savedSeconds = "saved_seconds"
                case listenedSeconds = "listened_seconds"
                case readingSeconds = "reading_seconds"
            }
        }
        let f = try await getJSON(path: "/v1/items/\(itemId)/stats", as: Full.self)
        return ItemStatsDTO(
            savedSeconds: f.savedSeconds,
            listenedSeconds: f.listenedSeconds,
            readingSeconds: f.readingSeconds
        )
    }

    func putLifetime(body: LifetimeStatsDTO) async throws {
        var req = try await authorizedRequest(path: "/v1/stats/lifetime", method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await performData(req)
        try throwIfNeeded(resp, data: data)
    }

    func getLifetime() async throws -> (saved: Double, played: Double) {
        struct Full: Decodable {
            let savedSeconds: Double
            let playedSeconds: Double
            enum CodingKeys: String, CodingKey {
                case savedSeconds = "saved_seconds"
                case playedSeconds = "played_seconds"
            }
        }
        let f = try await getJSON(path: "/v1/stats/lifetime", as: Full.self)
        return (f.savedSeconds, f.playedSeconds)
    }

    // MARK: - HTTP helpers

    private struct EmptyBody: Encodable {}

    private func authorizedRequest(path: String, method: String) async throws -> URLRequest {
        let base = try await resolveBaseURL()
        guard let token = try keychain.loadToken() else {
            throw LibrarySourceError.notAuthenticated
        }
        let url: URL
        if path.contains("?") {
            guard let composed = URL(string: base.absoluteString + path) else {
                throw LibrarySourceError.network(underlying: "Invalid URL path")
            }
            url = composed
        } else {
            url = base.appending(path: path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func performData(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            if Self.isLikelyConnectivityFailure(error) {
                invalidateResolvedBase()
                // Rebuild against a freshly probed base and retry once.
                var retry = request
                let base = try await resolveBaseURL(forceProbe: true)
                if let oldURL = request.url {
                    let path = oldURL.path + (oldURL.query.map { "?\($0)" } ?? "")
                    let pathPart = path.hasPrefix("/") ? path : "/" + path
                    retry.url = URL(string: base.absoluteString + pathPart)
                }
                return try await session.data(for: retry)
            }
            throw error
        }
    }

    private static func isLikelyConnectivityFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case URLError.timedOut.rawValue,
                 URLError.cannotConnectToHost.rawValue,
                 URLError.networkConnectionLost.rawValue,
                 URLError.notConnectedToInternet.rawValue,
                 URLError.dnsLookupFailed.rawValue,
                 URLError.cannotFindHost.rawValue:
                return true
            default:
                break
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isLikelyConnectivityFailure(underlying)
        }
        return false
    }

    private func getJSON<T: Decodable>(path: String, as: T.Type) async throws -> T {
        let req = try await authorizedRequest(path: path, method: "GET")
        let (data, resp) = try await performData(req)
        try throwIfNeeded(resp, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LibrarySourceError.decoding(String(describing: error))
        }
    }

    private func postJSON<B: Encodable, T: Decodable>(path: String, body: B, as: T.Type) async throws -> T {
        var req = try await authorizedRequest(path: path, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await performData(req)
        try throwIfNeeded(resp, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LibrarySourceError.decoding(String(describing: error))
        }
    }

    private func putJSON<B: Encodable, T: Decodable>(path: String, body: B, as: T.Type) async throws -> T {
        var req = try await authorizedRequest(path: path, method: "PUT")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await performData(req)
        try throwIfNeeded(resp, data: data)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LibrarySourceError.decoding(String(describing: error))
        }
    }

    private func throwIfNeeded(_ resp: URLResponse, data: Data?) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw LibrarySourceError.network(underlying: "Invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if http.statusCode == 401 {
                throw LibrarySourceError.notAuthenticated
            }
            throw LibrarySourceError.network(underlying: "HTTP \(http.statusCode) \(body)")
        }
    }
}
