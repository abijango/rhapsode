import Foundation

/// Wire model for KOReader Progress Sync GET/PUT payloads.
struct KOSyncProgress: Codable, Sendable, Equatable {
    var document: String?
    var progress: String?
    var percentage: Double?
    /// Unix seconds (KOReader protocol).
    var timestamp: Double?
    var device: String?
    var device_id: String?

    var fraction: Double? {
        guard let percentage, percentage.isFinite, percentage > 0 else { return nil }
        return min(1, percentage)
    }

    var updatedAt: Date? {
        guard let timestamp, timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}

/// Minimal HTTP client for the KOReader Progress Sync protocol
/// (`application/vnd.koreader.v1+json`).
actor KOSyncClient {
    var serverURL: String
    var username: String
    var userkey: String
    var deviceName: String
    var deviceID: String

    private var usesHTTPBasic = false
    /// Last password (plain) if Basic auth fallback is needed.
    private var passwordHint: String?

    init(
        serverURL: String,
        username: String,
        userkey: String,
        deviceName: String = KOSyncSettings.deviceName,
        deviceID: String = KOSyncSettings.deviceID
    ) {
        var base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        self.serverURL = base
        self.username = username
        self.userkey = userkey
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    static func fromSettings() -> KOSyncClient? {
        guard KOSyncSettings.isConfigured,
              let key = KOSyncSettings.userkey, !key.isEmpty
        else { return nil }
        return KOSyncClient(
            serverURL: KOSyncSettings.serverURL,
            username: KOSyncSettings.username,
            userkey: key
        )
    }

    // MARK: - Auth

    struct ConnectResult: Sendable {
        var success: Bool
        var message: String
    }

    /// Validate credentials. `password` is the plain password (hashed to userkey for headers).
    /// On 401, attempts `/users/create` (register) once — same as Readest.
    func connect(username: String, password: String) async -> ConnectResult {
        self.username = username
        let key = PartialMD5.md5Hex(Data(password.utf8))
        self.userkey = key
        self.passwordHint = password
        self.usesHTTPBasic = false

        do {
            let auth = try await request(path: "/users/auth", method: "GET", auth: true)
            if (200..<300).contains(auth.status) {
                guard isJSONObject(auth.data) else {
                    return .init(success: false, message: "Not a KOReader Sync server. Check the Server URL.")
                }
                return .init(success: true, message: "Login successful.")
            }

            if auth.status == 401 || auth.status == 400 {
                let body = try JSONSerialization.data(withJSONObject: [
                    "username": username,
                    "password": key,
                ])
                let reg = try await request(
                    path: "/users/create",
                    method: "POST",
                    auth: false,
                    body: body
                )
                if (200..<300).contains(reg.status) {
                    guard isJSONObject(reg.data) else {
                        return .init(success: false, message: "Not a KOReader Sync server. Check the Server URL.")
                    }
                    return .init(success: true, message: "Registration successful.")
                }
                if reg.status == 402 {
                    return .init(success: false, message: "Invalid credentials.")
                }
                let msg = jsonMessage(reg.data) ?? "Registration failed (\(reg.status))."
                return .init(success: false, message: msg)
            }

            let msg = jsonMessage(auth.data) ?? "Authorization failed (\(auth.status))."
            return .init(success: false, message: msg)
        } catch {
            return .init(success: false, message: error.localizedDescription)
        }
    }

    // MARK: - Progress

    func getProgress(documentHash: String) async throws -> KOSyncProgress? {
        let path = "/syncs/progress/\(documentHash)"
        let res = try await request(path: path, method: "GET", auth: true)
        guard (200..<300).contains(res.status) else {
            if res.status == 404 { return nil }
            throw KOSyncError.http(res.status, jsonMessage(res.data))
        }
        guard let data = res.data, !data.isEmpty else { return nil }
        let decoded = try JSONDecoder().decode(KOSyncProgress.self, from: data)
        let hasPosition =
            (decoded.progress.map { !$0.isEmpty } ?? false)
            || (decoded.percentage.map { $0.isFinite } ?? false)
        guard hasPosition else { return nil }
        var out = decoded
        if out.document == nil { out.document = documentHash }
        return out
    }

    func updateProgress(
        documentHash: String,
        progress: String,
        percentage: Double
    ) async throws {
        let payload: [String: Any] = [
            "document": documentHash,
            "progress": progress,
            "percentage": percentage,
            "device": deviceName,
            "device_id": deviceID,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let res = try await request(path: "/syncs/progress", method: "PUT", auth: true, body: body)
        guard (200..<300).contains(res.status) else {
            throw KOSyncError.http(res.status, jsonMessage(res.data))
        }
    }

    // MARK: - HTTP

    private struct RawResponse {
        var status: Int
        var data: Data?
    }

    private func request(
        path: String,
        method: String,
        auth: Bool,
        body: Data? = nil
    ) async throws -> RawResponse {
        var first = try await perform(path: path, method: method, auth: auth, body: body, basic: usesHTTPBasic)
        // Some CWA builds return 400/401 for X-Auth; retry with HTTP Basic once.
        if auth, (first.status == 401 || first.status == 400), !usesHTTPBasic, passwordHint != nil {
            usesHTTPBasic = true
            let second = try await perform(path: path, method: method, auth: auth, body: body, basic: true)
            if !(200..<300).contains(second.status) {
                usesHTTPBasic = false
            }
            first = second
        }
        return first
    }

    private func perform(
        path: String,
        method: String,
        auth: Bool,
        body: Data?,
        basic: Bool
    ) async throws -> RawResponse {
        guard let url = URL(string: serverURL + path) else {
            throw KOSyncError.badURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/vnd.koreader.v1+json", forHTTPHeaderField: "Accept")
        if method != "GET" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if auth {
            if basic, let passwordHint {
                let raw = "\(username):\(passwordHint)"
                let token = Data(raw.utf8).base64EncodedString()
                req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            } else {
                req.setValue(username, forHTTPHeaderField: "X-Auth-User")
                req.setValue(userkey, forHTTPHeaderField: "X-Auth-Key")
            }
        }
        req.httpBody = body
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return RawResponse(status: status, data: data)
    }

    private func isJSONObject(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return obj is [String: Any] || obj is [Any]
    }

    private func jsonMessage(_ data: Data?) -> String? {
        guard let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["message"] as? String) ?? (obj["error"] as? String)
    }
}

enum KOSyncError: LocalizedError {
    case badURL
    case http(Int, String?)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .badURL: "Invalid KOReader Sync server URL."
        case .http(let code, let msg): msg ?? "KOReader Sync error (\(code))."
        case .notConfigured: "KOReader Sync is not configured."
        }
    }
}
