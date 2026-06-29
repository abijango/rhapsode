import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Dropbox OAuth 2 with PKCE (no app secret). Runs the authorize step in an
/// `ASWebAuthenticationSession` and exchanges the code for tokens. Requests
/// `token_access_type=offline` so we get a long-lived refresh token.
@MainActor
final class DropboxOAuth: NSObject {

    /// Run the full interactive connect flow and return tokens.
    func connect() async throws -> DropboxTokens {
        let verifier = Self.codeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let code = try await authorize(challenge: challenge)
        return try await exchange(code: code, verifier: verifier)
    }

    /// Refresh an access token using the stored refresh token.
    static func refresh(refreshToken: String) async throws -> DropboxTokens {
        var req = URLRequest(url: URL(string: DropboxConfig.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": DropboxConfig.appKey,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkOK(response, data)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return DropboxTokens(
            refreshToken: refreshToken, // refresh tokens are reused across refreshes
            accessToken: token.access_token,
            accessTokenExpiry: Date().addingTimeInterval(TimeInterval(token.expires_in))
        )
    }

    // MARK: Authorize

    private func authorize(challenge: String) async throws -> String {
        var comps = URLComponents(string: DropboxConfig.authorizeURL)!
        comps.queryItems = [
            .init(name: "client_id", value: DropboxConfig.appKey),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: DropboxConfig.redirectURI),
            .init(name: "token_access_type", value: "offline"),
            .init(name: "scope", value: DropboxConfig.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        let authURL = comps.url!

        return try await withCheckedThrowingContinuation { continuation in
            // The completion handler is invoked by ASWebAuthenticationSession on a background
            // XPC queue, NOT the main thread. `DropboxOAuth` is @MainActor, so without an
            // explicit annotation this closure inherits main-actor isolation and the Swift 6
            // runtime traps (`_dispatch_assert_queue_fail`) when it runs off-main. Mark it
            // @Sendable so it is non-isolated: its body only resumes the continuation (safe from
            // any thread) and touches no main-actor state. The awaiting `connect()` resumes back
            // on the main actor automatically.
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: DropboxConfig.callbackScheme
            ) { @Sendable callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard
                    let callbackURL,
                    let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "code" })?.value
                else {
                    continuation.resume(throwing: LibrarySourceError.notAuthenticated)
                    return
                }
                continuation.resume(returning: code)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func exchange(code: String, verifier: String) async throws -> DropboxTokens {
        var req = URLRequest(url: URL(string: DropboxConfig.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": DropboxConfig.appKey,
            "redirect_uri": DropboxConfig.redirectURI,
            "code_verifier": verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        try Self.checkOK(response, data)
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let refresh = token.refresh_token else {
            throw LibrarySourceError.decoding("missing refresh_token")
        }
        return DropboxTokens(
            refreshToken: refresh,
            accessToken: token.access_token,
            accessTokenExpiry: Date().addingTimeInterval(TimeInterval(token.expires_in))
        )
    }

    // MARK: PKCE helpers

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func formBody(_ params: [String: String]) -> Data {
        params.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(key)=\(v)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    private static func checkOK(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LibrarySourceError.network(underlying: "OAuth HTTP error: \(body)")
        }
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }
}

extension DropboxOAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension CharacterSet {
    /// URL-query-safe set (stricter than `.urlQueryAllowed`, which permits `&` `=`).
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
