import Foundation

/// Hardcover.app integration preferences. The Personal Access Token is a full-account
/// credential, so it lives in the Keychain (same pattern as `KOSyncSettings.userkey`);
/// everything else is a plain preference.
enum HardcoverSettings {
    private static let enabledKey = "hardcover.enabled"
    private static let usernameKey = "hardcover.username"
    private static let finishPromptKey = "hardcover.finishPromptEnabled"
    private static let keychainService = "com.naufalmir.rhapsode.hardcover"
    private static let tokenAccount = "token"

    /// GraphQL endpoint. Same API the Hardcover website and mobile apps use.
    static let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!

    /// Deep link to the New API Key form with the scopes we need pre-checked, so the user
    /// doesn't have to hunt through the scope list. Path and query shape verified against
    /// `API_NEW_TOKEN_URL` in hardcoverapp/hardcover-docs `src/Consts.ts`; unknown scopes are
    /// silently dropped by the form rather than rejected, so this can't break on a rename.
    static let newTokenURL = URL(string:
        "https://hardcover.app/account/api/keys/new?scope=read:library+write:library")!

    /// Fraction of the book past which we offer to mark it Read.
    static let finishThreshold = 0.98

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Hardcover username, cached from the last successful `Verify` purely for display.
    static var username: String? {
        get { UserDefaults.standard.string(forKey: usernameKey) }
        set { UserDefaults.standard.set(newValue, forKey: usernameKey) }
    }

    /// Whether finishing a book offers the rating sheet. On by default.
    static var finishPromptEnabled: Bool {
        get { UserDefaults.standard.object(forKey: finishPromptKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: finishPromptKey) }
    }

    /// Personal Access Token. Keychain-backed.
    static var token: String? {
        get { KeychainStringStore.load(service: keychainService, account: tokenAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                try? KeychainStringStore.save(newValue, service: keychainService, account: tokenAccount)
            } else {
                try? KeychainStringStore.clear(service: keychainService, account: tokenAccount)
            }
        }
    }

    /// True when the integration is switched on AND we actually hold a token.
    static var isActive: Bool { isEnabled && (token?.isEmpty == false) }

    static func signOut() {
        token = nil
        username = nil
        isEnabled = false
    }
}
