import Foundation
import Security

// MARK: - Profile

/// One saved SMB storage (VidHub “Added Storage” row).
struct SmbStorageProfile: Identifiable, Codable, Equatable, Sendable, Hashable {
    var id: UUID
    /// User-facing name, e.g. "NAS" / "My SMB".
    var name: String
    var host: String
    var share: String
    var username: String
    var domain: String
    /// Paths relative to the share root.
    var audiobooksPath: String
    var booksPath: String
    var syncPath: String

    init(
        id: UUID = UUID(),
        name: String = "My SMB",
        host: String = "",
        share: String = "",
        username: String = "",
        domain: String = "",
        audiobooksPath: String = "Audiobooks",
        booksPath: String = "Books",
        /// Visible share-relative folder (no leading dot — Finder hides `.name` folders).
        syncPath: String = SmbConfig.defaultSyncPath
    ) {
        self.id = id
        self.name = name
        self.host = SmbConfig.sanitizeHost(host)
        self.share = SmbConfig.sanitizeShare(share)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.audiobooksPath = SmbConfig.normalizeRelPath(audiobooksPath.isEmpty ? "Audiobooks" : audiobooksPath)
        self.booksPath = SmbConfig.normalizeRelPath(booksPath.isEmpty ? "Books" : booksPath)
        self.syncPath = SmbConfig.normalizeRelPath(
            syncPath.isEmpty ? SmbConfig.defaultSyncPath : syncPath)
    }

    var isConfigured: Bool {
        !host.isEmpty && !share.isEmpty && (try? SmbKeychain(profileId: id).loadPassword()) != nil
    }

    var serverURL: URL? {
        let h = host
        guard !h.isEmpty else { return nil }
        if h.lowercased().hasPrefix("smb://") { return URL(string: h) }
        return URL(string: "smb://\(h)")
    }

    var credentialUser: String {
        if domain.isEmpty { return username }
        return "\(domain)\\\(username)"
    }

    var listSubtitle: String {
        if host.isEmpty { return "Not configured" }
        if share.isEmpty { return host }
        return "\(share) · \(host)"
    }
}

// MARK: - Store

/// Multi-profile SMB config (VidHub-style). Active profile drives `SmbLibrarySource`.
enum SmbConfig {
    private static let profilesKey = "rhapsode.smb.profiles.v2"
    private static let activeIdKey = "rhapsode.smb.activeProfileId"
    private static let preferKey = "rhapsode.smb.prefer"

    // Legacy single-source keys (migrated once)
    private static let hostKey = "rhapsode.smb.host"
    private static let shareKey = "rhapsode.smb.share"
    private static let userKey = "rhapsode.smb.username"
    private static let domainKey = "rhapsode.smb.domain"
    private static let audioPathKey = "rhapsode.smb.audiobooksPath"
    private static let booksPathKey = "rhapsode.smb.booksPath"
    private static let syncPathKey = "rhapsode.smb.syncPath"

    /// Progress/stats folder on the share (visible — no leading `.`).
    static let defaultSyncPath = "rhapsode-sync"
    /// Previous default; Finder/Files hide it as a dot-folder.
    private static let legacyHiddenSyncPath = ".rhapsode-sync"

    // MARK: Preferences

    static var preferSmb: Bool {
        get { UserDefaults.standard.bool(forKey: preferKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferKey) }
    }

    static var profiles: [SmbStorageProfile] {
        get {
            migrateLegacyIfNeeded()
            migrateHiddenSyncPathIfNeeded()
            guard let data = UserDefaults.standard.data(forKey: profilesKey),
                  let list = try? JSONDecoder().decode([SmbStorageProfile].self, from: data) else {
                return []
            }
            return list
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: profilesKey)
            }
        }
    }

    static var activeProfileId: UUID? {
        get {
            migrateLegacyIfNeeded()
            guard let s = UserDefaults.standard.string(forKey: activeIdKey) else { return nil }
            return UUID(uuidString: s)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.uuidString, forKey: activeIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeIdKey)
            }
        }
    }

    static var activeProfile: SmbStorageProfile? {
        let list = profiles
        if let id = activeProfileId, let p = list.first(where: { $0.id == id }) { return p }
        return list.first
    }

    static var isConfigured: Bool {
        activeProfile?.isConfigured == true
    }

    static var shouldUseSmb: Bool {
        preferSmb && isConfigured
    }

    // MARK: Active-profile convenience (used by SmbLibrarySource)

    static var host: String { activeProfile?.host ?? "" }
    static var share: String { activeProfile?.share ?? "" }
    static var username: String { activeProfile?.username ?? "" }
    static var domain: String { activeProfile?.domain ?? "" }
    static var audiobooksPath: String { activeProfile?.audiobooksPath ?? "Audiobooks" }
    static var booksPath: String { activeProfile?.booksPath ?? "Books" }
    static var syncPath: String { activeProfile?.syncPath ?? defaultSyncPath }
    static var serverURL: URL? { activeProfile?.serverURL }
    static var credentialUser: String { activeProfile?.credentialUser ?? "" }
    static var displayName: String { activeProfile?.name ?? "SMB" }

    static func upsert(_ profile: SmbStorageProfile) {
        var list = profiles
        if let i = list.firstIndex(where: { $0.id == profile.id }) {
            list[i] = profile
        } else {
            list.append(profile)
        }
        profiles = list
    }

    static func deleteProfile(id: UUID) {
        profiles = profiles.filter { $0.id != id }
        try? SmbKeychain(profileId: id).clear()
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
            if profiles.isEmpty { preferSmb = false }
        }
    }

    static func setActive(id: UUID) {
        activeProfileId = id
        preferSmb = true
        RhapsodeServerConfig.preferServer = false
    }

    // MARK: Sanitize

    static func sanitizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("smb://") { s = String(s.dropFirst(6)) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        if let colon = s.firstIndex(of: ":"), s[colon...].dropFirst().allSatisfy(\.isNumber) {
            s = String(s[..<colon])
        }
        return s
    }

    static func sanitizeShare(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if s.contains("/") {
            s = s.split(separator: "/").map(String.init).last ?? s
        }
        return s
    }

    static func normalizeRelPath(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Migration

    private static let migratedKey = "rhapsode.smb.migrated.v2"
    private static let syncPathVisibleMigratedKey = "rhapsode.smb.syncPathVisible.v1"

    /// Rename profile `syncPath` from `.rhapsode-sync` → `rhapsode-sync` so the
    /// folder is visible in Finder / Files on every device. (Does not move NAS
    /// files; next push recreates under the new path. Old folder can be deleted.)
    private static func migrateHiddenSyncPathIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: syncPathVisibleMigratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: syncPathVisibleMigratedKey) }

        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              var list = try? JSONDecoder().decode([SmbStorageProfile].self, from: data) else {
            return
        }
        var changed = false
        for i in list.indices {
            let p = list[i].syncPath
            if p == legacyHiddenSyncPath || p == "/\(legacyHiddenSyncPath)" {
                list[i].syncPath = defaultSyncPath
                changed = true
            }
        }
        if changed, let encoded = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(encoded, forKey: profilesKey)
        }
    }

    private static func migrateLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: migratedKey) }

        if UserDefaults.standard.data(forKey: profilesKey) != nil { return }

        let host = UserDefaults.standard.string(forKey: hostKey) ?? ""
        let share = UserDefaults.standard.string(forKey: shareKey) ?? ""
        guard !host.isEmpty || !share.isEmpty else { return }

        let id = UUID()
        let legacySync = UserDefaults.standard.string(forKey: syncPathKey) ?? defaultSyncPath
        let sync = (legacySync == legacyHiddenSyncPath) ? defaultSyncPath : legacySync
        let profile = SmbStorageProfile(
            id: id,
            name: share.isEmpty ? "NAS" : share,
            host: host,
            share: share,
            username: UserDefaults.standard.string(forKey: userKey) ?? "",
            domain: UserDefaults.standard.string(forKey: domainKey) ?? "",
            audiobooksPath: UserDefaults.standard.string(forKey: audioPathKey) ?? "Audiobooks",
            booksPath: UserDefaults.standard.string(forKey: booksPathKey) ?? "Books",
            syncPath: sync
        )
        // Move legacy password into profile keychain slot
        if let pass = try? SmbKeychain(profileId: nil).loadPassword(), !pass.isEmpty {
            try? SmbKeychain(profileId: id).savePassword(pass)
            try? SmbKeychain(profileId: nil).clear()
        }
        if let data = try? JSONEncoder().encode([profile]) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(id.uuidString, forKey: activeIdKey)
    }
}

// MARK: - Keychain (per profile)

struct SmbKeychain: Sendable {
    let service: String
    let account: String

    /// `profileId == nil` is the legacy single password account.
    init(profileId: UUID?, service: String = "com.naufalmir.rhapsode.smb") {
        self.service = service
        self.account = profileId.map { "password.\($0.uuidString)" } ?? "password"
    }

    func savePassword(_ password: String) throws {
        let data = Data(password.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainTokenStore.KeychainError.unhandled(status)
        }
    }

    func loadPassword() throws -> String? {
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
