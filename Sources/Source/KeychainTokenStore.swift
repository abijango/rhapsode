import Foundation
import Security

/// Persisted Dropbox OAuth tokens. The refresh token is long-lived; the access
/// token is short-lived and refreshed on demand.
struct DropboxTokens: Codable, Sendable {
    var refreshToken: String
    var accessToken: String
    /// Absolute expiry of `accessToken`.
    var accessTokenExpiry: Date
}

/// Stores `DropboxTokens` in the Keychain (generic password). No paid entitlement
/// required — the basic keychain is available on a free provisioning profile.
struct KeychainTokenStore: Sendable {
    let service: String
    let account: String

    init(service: String = "com.naufalmir.rhapsode.dropbox", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    func save(_ tokens: DropboxTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
    }

    func load() throws -> DropboxTokens? {
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
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unhandled(status)
        }
        return try JSONDecoder().decode(DropboxTokens.self, from: data)
    }

    func clear() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandled(status)
        }
    }

    enum KeychainError: Error { case unhandled(OSStatus) }
}
