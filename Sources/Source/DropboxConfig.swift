import Foundation

/// Dropbox app registration + endpoint configuration.
///
/// Setup (one-time, at https://www.dropbox.com/developers/apps):
///   1. Create app → "Scoped access" → "App folder" access → name it (folder
///      becomes `/Apps/<name>/`).
///   2. Permissions tab → enable `files.metadata.read` and `files.content.read`.
///   3. Settings tab → OAuth 2 → Redirect URIs → add `rhapsode://oauth`.
///   4. Copy the **App key** into `appKey` below.
///
/// PKCE is used (no app secret), so the app key is the only credential and is safe
/// to embed in the client.
enum DropboxConfig {
    static let appKey = "36lgcvj3ncul21f"

    /// Must exactly match a Redirect URI registered in the Dropbox app console.
    static let redirectURI = "rhapsode://oauth"

    /// Custom URL scheme component of `redirectURI`, for ASWebAuthenticationSession.
    static let callbackScheme = "rhapsode"

    /// Scopes: read access for list + longpoll + download, plus **app-folder write**
    /// (`files.content.write`) for cross-device progress sync (Phase 5) — used only
    /// to write small progress JSON files under `/.rhapsode-sync` in the app folder.
    /// Still App-folder-scoped (never Full Dropbox). Existing connections made before
    /// this scope was added must reconnect to grant write.
    static let scopes = ["files.metadata.read", "files.content.read", "files.content.write"]

    /// The two watched roots inside the app folder (App-folder access makes these
    /// look root-relative to the Dropbox API).
    static let audiobooksPath = "/Audiobooks"
    static let booksPath = "/Books"

    // Endpoints.
    static let authorizeURL = "https://www.dropbox.com/oauth2/authorize"
    static let tokenURL = "https://api.dropboxapi.com/oauth2/token"
    static let apiBase = "https://api.dropboxapi.com/2"
    static let contentBase = "https://content.dropboxapi.com/2"
    static let notifyBase = "https://notify.dropboxapi.com/2"

    static var isConfigured: Bool { appKey != "REPLACE_WITH_DROPBOX_APP_KEY" && !appKey.isEmpty }
}
