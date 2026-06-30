import AuthenticationServices
import CryptoKit
import Foundation
import os.log

// MARK: - BoxAuth

// OAuth2 + PKCE (RFC 7636) for Box.com

public actor BoxAuth {
    private static var clientID: String {
        SharedConfig.string("CLIENT_ID", providerID: "box") ?? ""
    }

    private static var clientSecret: String? {
        SharedConfig.string("CLIENT_SECRET", providerID: "box")
    }

    private static var redirectURI: String {
        SharedConfig.string("REDIRECT_URI", providerID: "box") ?? "stratus://oauth/box"
    }

    private static let authURL = "https://account.box.com/api/oauth2/authorize"
    private static let tokenURL = "https://api.box.com/oauth2/token"
    private static var scope: String {
        SharedConfig.string("SCOPES", providerID: "box") ?? "root_readwrite manage_webhooks"
    }

    private let vault = CredentialVault.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BoxAuth")

    public init() {}

    // MARK: - Initiate Auth

    public func authenticate(presentingWindow: NSWindow?) async throws -> OAuthCredential {
        guard !Self.clientID.isEmpty else {
            throw ProviderError
                .authenticationFailed("Missing STRATUS_BOX_CLIENT_ID in shared/oauth.config or environment")
        }

        let (verifier, challenge) = generatePKCE()
        let state = UUID().uuidString

        guard var components = URLComponents(string: Self.authURL) else {
            throw ProviderError.authenticationFailed("Invalid Box auth URL")
        }
        components.queryItems = [
            .init(name: "client_id", value: Self.clientID),
            .init(name: "redirect_uri", value: Self.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let authorizationURL = components.url else {
            throw ProviderError.authenticationFailed("Could not build Box authorization URL")
        }

        let callbackURL: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authorizationURL,
                callbackURLScheme: "stratus"
            ) { url, error in
                if let error { continuation.resume(throwing: error)
                    return
                }
                guard let url
                else { continuation.resume(throwing: ProviderError.authenticationFailed("No callback URL"))
                    return
                }
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
        guard let tokenURLValue = URL(string: Self.tokenURL) else {
            throw ProviderError.authenticationFailed("Invalid token URL")
        }
        var request = URLRequest(url: tokenURLValue)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        var formItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        if let clientSecret = Self.clientSecret {
            formItems.append(URLQueryItem(name: "client_secret", value: clientSecret))
        }
        components.queryItems = formItems
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String
        else {
            throw ProviderError.authenticationFailed("Box token exchange failed")
        }
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        logger.info("Box authentication successful")
        return OAuthCredential(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: Self.scope
        )
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
