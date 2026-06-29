import Foundation
import AuthenticationServices
import CryptoKit
import os.log

// MARK: - Google OAuth2 via ASWebAuthenticationSession

public actor GoogleDriveAuth {
    public static let shared = GoogleDriveAuth()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "GoogleDriveAuth")
    private let vault = CredentialVault.shared

    private static let authURL = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let revokeURL = "https://oauth2.googleapis.com/revoke"
    // Scopes: drive.file for app-created files, drive for full access
    static let scope = "https://www.googleapis.com/auth/drive"
    private static let redirectURI = "com.stratus.cloudmanager:/oauth2callback"

    private init() {}

    // MARK: - Authorization Code + PKCE

    public func authorize(clientID: String, presentationContext: ASWebAuthenticationPresentationContextProviding) async throws -> OAuthCredential {
        let (codeVerifier, codeChallenge) = generatePKCE()
        let state = UUID().uuidString

        var comps = URLComponents(string: Self.authURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        let authURL = comps.url!
        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "com.stratus.cloudmanager") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: AuthError.cancelled) }
            }
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.noAuthorizationCode
        }

        return try await exchangeCode(code: code, codeVerifier: codeVerifier, clientID: clientID)
    }

    public func refreshToken(credential: OAuthCredential, clientID: String) async throws -> OAuthCredential {
        guard let refreshToken = credential.refreshToken else { throw AuthError.noRefreshToken }

        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseTokenResponse(data: data, existingRefreshToken: refreshToken)
    }

    // MARK: - Private

    private func exchangeCode(code: String, codeVerifier: String, clientID: String) async throws -> OAuthCredential {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID)&redirect_uri=\(Self.redirectURI)&grant_type=authorization_code&code=\(code)&code_verifier=\(codeVerifier)"
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        return try parseTokenResponse(data: data, existingRefreshToken: nil)
    }

    private func parseTokenResponse(data: Data, existingRefreshToken: String?) throws -> OAuthCredential {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw AuthError.invalidTokenResponse
        }
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let refreshToken = (json["refresh_token"] as? String) ?? existingRefreshToken
        let scope = json["scope"] as? String
        return OAuthCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: scope
        )
    }

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let challengeData = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(challengeData).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (verifier, challenge)
    }
}

public enum AuthError: Error, Sendable {
    case cancelled
    case noAuthorizationCode
    case noRefreshToken
    case invalidTokenResponse
    case pkceGenerationFailed
}
