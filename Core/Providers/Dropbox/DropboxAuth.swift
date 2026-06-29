import Foundation
import AuthenticationServices
import CryptoKit
import os.log

// MARK: - Dropbox OAuth2 PKCE

public actor DropboxAuth {
    public static let shared = DropboxAuth()
    private static let authURL = "https://www.dropbox.com/oauth2/authorize"
    private static let tokenURL = "https://api.dropboxapi.com/oauth2/token"
    private static let redirectURI = "com.stratus.cloudmanager:/dropbox/callback"
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DropboxAuth")
    private init() {}

    public func authorize(appKey: String, context: ASWebAuthenticationPresentationContextProviding) async throws -> OAuthCredential {
        let (verifier, challenge) = generatePKCE()
        let state = UUID().uuidString

        guard var comps = URLComponents(string: Self.authURL) else {
            throw AuthError.invalidTokenResponse
        }
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
        ]
        guard let authURL = comps.url else {
            throw AuthError.invalidTokenResponse
        }

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "com.stratus.cloudmanager") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: AuthError.cancelled) }
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.noAuthorizationCode
        }

        var request = URLRequest(url: URL(string: Self.tokenURL) ?? URL(fileURLWithPath: "/"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "code=\(code)&grant_type=authorization_code&client_id=\(appKey)&redirect_uri=\(Self.redirectURI)&code_verifier=\(verifier)"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AuthError.invalidTokenResponse
        }
        return OAuthCredential(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: Date().addingTimeInterval(14400)
        )
    }

    public func refreshToken(credential: OAuthCredential, appKey: String) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken else { throw AuthError.noRefreshToken }
        var request = URLRequest(url: URL(string: Self.tokenURL) ?? URL(fileURLWithPath: "/"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)&client_id=\(appKey)"
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AuthError.invalidTokenResponse
        }
        return OAuthCredential(accessToken: accessToken, refreshToken: refreshToken,
                                expiresAt: Date().addingTimeInterval((json["expires_in"] as? TimeInterval) ?? 14400))
    }

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let hash = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return (verifier, challenge)
    }
}
