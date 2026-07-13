import Foundation
import Security

/// User-facing connection to a self-hosted rhapsode-server instance.
///
/// Two base URLs are supported so the same token works at home and away:
/// - **Remote** (e.g. Tailscale MagicDNS) — always available when the VPN is up
/// - **Home** (LAN IP / hostname) — preferred when reachable so you can leave Tailscale off
///
/// The client probes candidates (home first, then remote) with a short timeout and
/// remembers the last working base URL for subsequent requests.
enum RhapsodeServerConfig {
    private static let primaryURLKey = "rhapsode.server.baseURL"
    private static let secondaryURLKey = "rhapsode.server.homeBaseURL"
    private static let activeURLKey = "rhapsode.server.activeBaseURL"
    private static let preferKey = "rhapsode.server.preferOverDropbox"

    // MARK: - Stored URLs

    /// Remote / Tailscale base URL, e.g. `http://nas.tailca881.ts.net:13379`.
    /// Stored under the original key for migration.
    static var baseURLString: String {
        get { UserDefaults.standard.string(forKey: primaryURLKey) ?? "" }
        set { UserDefaults.standard.set(Self.normalizedURLString(newValue), forKey: primaryURLKey) }
    }

    /// Optional home LAN URL, e.g. `http://192.168.1.50:13379` or `http://nas.local:13379`.
    static var homeURLString: String {
        get { UserDefaults.standard.string(forKey: secondaryURLKey) ?? "" }
        set { UserDefaults.standard.set(Self.normalizedURLString(newValue), forKey: secondaryURLKey) }
    }

    static var primaryURL: URL? { parseURL(baseURLString) }
    static var homeURL: URL? { parseURL(homeURLString) }

    /// Last successfully probed base URL (either home or remote).
    static var activeBaseURLString: String? {
        get { UserDefaults.standard.string(forKey: activeURLKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(Self.normalizedURLString(newValue), forKey: activeURLKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeURLKey)
            }
        }
    }

    static var activeBaseURL: URL? {
        guard let s = activeBaseURLString else { return nil }
        return parseURL(s)
    }

    /// Best synchronous base for building requests: last-good, else home, else remote.
    /// Prefer calling `RhapsodeServerClient.resolveBaseURL()` for a live pick.
    static var baseURL: URL? {
        if let active = activeBaseURL,
           candidateURLs.contains(where: { $0.absoluteString == active.absoluteString }) {
            return active
        }
        return candidateURLs.first
    }

    /// Probe order: **home LAN first** (when set), then remote (Tailscale).
    /// Home is tried first so you can leave Tailscale off on the home network.
    static var candidateURLs: [URL] {
        var list: [URL] = []
        if let home = homeURL { list.append(home) }
        if let primary = primaryURL,
           !list.contains(where: { $0.absoluteString == primary.absoluteString }) {
            list.append(primary)
        }
        return list
    }

    static func rememberActiveBaseURL(_ url: URL) {
        activeBaseURLString = url.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func clearActiveBaseURL() {
        activeBaseURLString = nil
    }

    // MARK: - Flags

    /// When true and a token is stored, the app uses rhapsode-server instead of Dropbox.
    static var preferServer: Bool {
        get { UserDefaults.standard.bool(forKey: preferKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferKey) }
    }

    static var hasToken: Bool {
        guard let token = try? RhapsodeServerKeychain().loadToken() else { return false }
        return !token.isEmpty
    }

    static var isConfigured: Bool {
        !candidateURLs.isEmpty && hasToken
    }

    /// True when server URL + token are set and the user opted in.
    /// Evaluated at app launch when wiring `SyncManager` (restart after changing).
    static var shouldUseServer: Bool {
        preferServer && isConfigured
    }

    // MARK: - Parsing

    private static func normalizedURLString(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func parseURL(_ s: String) -> URL? {
        guard !s.isEmpty, let u = URL(string: s), u.scheme != nil, u.host != nil else { return nil }
        return u
    }
}

/// Keychain storage for the rhapsode-server device API token.
struct RhapsodeServerKeychain: Sendable {
    let service: String
    let account: String

    init(service: String = "com.naufalmir.rhapsode.server", account: String = "apiToken") {
        self.service = service
        self.account = account
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let data = Data(trimmed.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainTokenStore.KeychainError.unhandled(status) }
    }

    func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else {
            throw KeychainTokenStore.KeychainError.unhandled(status)
        }
        return s
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStore.KeychainError.unhandled(status)
        }
    }
}
