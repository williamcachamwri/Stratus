import Foundation
import AuthenticationServices
import CryptoKit
import os.log

// MARK: - BoxAuth
// OAuth2 + PKCE (RFC 7636) for Box.com

public actor BoxAuth {
    private static let clientID     = "YOUR_BOX_CLIENT_ID"
    private static let redirectURI  = "stratus://oauth/box"
    private static let authURL      = "https://account.box.com/api/oauth2/authorize"
    private static let tokenURL     = "https://api.box.com/oauth2/token"
    private static let scope        = "root_readwrite manage_webhooks"

    private let vault = CredentialVault.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BoxAuth")

    public init() {}

    // MARK: - Initiate Auth

    public func authenticate(presentingWindow: NSWindow?) async throws -> OAuthCredential {
        let (verifier, challenge) = generatePKCE()
        let state = UUID().uuidString

        var components = URLComponents(string: Self.authURL)!
        components.queryItems = [
            .init(name: "client_id",             value: Self.clientID),
            .init(name: "redirect_uri",           value: Self.redirectURI),
            .init(name: "response_type",          value: "code"),
            .init(name: "state",                  value: state),
            .init(name: "code_challenge",         value: challenge),
            .init(name: "code_challenge_method",  value: "S256"),
        ]
        let authorizationURL = components.url!

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "stratus"
            ) { url, error in
                if let error { continuation.resume(throwing: error); return }
                guard let url else { continuation.resume(throwing: ProviderError.authenticationFailed("No callback URL")); return }
                continuation.resume(returning: url)
            }
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }

        let components2 = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
        guard let code = components2?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw ProviderError.authenticationFailed("No auth code in Box callback")
        }

        return try await exchangeCode(code, verifier: verifier)
    }

    // MARK: - Exchange Code

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthCredential {
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.redirectURI)",
            "client_id=\(Self.clientID)",
            "code_verifier=\(verifier)",
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw ProviderError.authenticationFailed("Box token exchange failed")
        }
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        logger.info("Box authentication successful")
        return OAuthCredential(accessToken: access, refreshToken: refresh,
                                expiresAt: Date().addingTimeInterval(expiresIn), scope: Self.scope)
    }

    // MARK: - PKCE

    private func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 64)
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
