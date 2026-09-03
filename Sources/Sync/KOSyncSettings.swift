import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif
// PartialMD5.md5Hex for password hashing

/// KOReader Progress Sync preferences (server, strategy, device identity).
/// Secrets (userkey) live in the Keychain; non-secrets in UserDefaults.
enum KOSyncSettings {
    enum Strategy: String, CaseIterable, Identifiable {
        /// Last-writer-wins by server timestamp vs local `progressUpdatedAt`.
        case silent
        /// Always push local (never apply remote on open).
        case send
        /// Always apply remote when present (never push over it on open).
        case receive
        /// Ask when remote is newer (reader conflict sheet).
        case prompt

        var id: String { rawValue }

        var label: String {
            switch self {
            case .silent: "Automatic (newest wins)"
            case .send: "This device only (send)"
            case .receive: "Prefer other devices (receive)"
            case .prompt: "Ask when conflict"
            }
        }
    }

    private static let enabledKey = "kosync.enabled"
    private static let serverKey = "kosync.serverURL"
    private static let usernameKey = "kosync.username"
    private static let strategyKey = "kosync.strategy"
    private static let deviceNameKey = "kosync.deviceName"
    private static let deviceIDKey = "kosync.deviceID"
    private static let keychainService = "com.naufalmir.rhapsode.kosync"
    private static let userkeyAccount = "userkey"

    /// Public KOReader sync server; shown by default until the user chooses another URL.
    static let defaultServerURL = "https://sync.koreader.rocks"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Base URL without trailing slash, e.g. `https://sync.koreader.rocks` or `http://192.168.1.10:7200`.
    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: serverKey) ?? defaultServerURL }
        set {
            var s = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            UserDefaults.standard.set(s, forKey: serverKey)
        }
    }

    static var username: String {
        get { UserDefaults.standard.string(forKey: usernameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    /// MD5 hex of the password (KOReader `X-Auth-Key`). Stored in Keychain.
    static var userkey: String? {
        get { KeychainStringStore.load(service: keychainService, account: userkeyAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                try? KeychainStringStore.save(newValue, service: keychainService, account: userkeyAccount)
            } else {
                try? KeychainStringStore.clear(service: keychainService, account: userkeyAccount)
            }
        }
    }

    static var strategy: Strategy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: strategyKey),
                  let s = Strategy(rawValue: raw) else { return .silent }
            return s
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: strategyKey) }
    }

    static var deviceName: String {
        get {
            if let s = UserDefaults.standard.string(forKey: deviceNameKey), !s.isEmpty {
                return s
            }
            #if canImport(UIKit)
            return UIDevice.current.name
            #else
            return "Rhapsode"
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: deviceNameKey) }
    }

    static var deviceID: String {
        get {
            if let s = UserDefaults.standard.string(forKey: deviceIDKey), !s.isEmpty {
                return s
            }
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: deviceIDKey)
            return id
        }
        set { UserDefaults.standard.set(newValue, forKey: deviceIDKey) }
    }

    /// Ready to talk to a server (enabled + URL + username + userkey).
    static var isConfigured: Bool {
        isEnabled
            && !serverURL.isEmpty
            && !username.isEmpty
            && !(userkey ?? "").isEmpty
    }

    /// When configured, ebook reading position syncs via KOReader instead of Dropbox/SMB/server.
    static var isEbookProgressAuthority: Bool { isConfigured }

    static func setPassword(_ password: String) {
        // KOReader hashes the password with MD5 for X-Auth-Key.
        userkey = PartialMD5.md5Hex(password.data(using: .utf8) ?? Data())
    }

    static func clearCredentials() {
        userkey = nil
    }
}

// MARK: - Keychain string helper

enum KeychainStringStore {
    static func save(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
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

    static func load(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear(service: String, account: String) throws {
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
