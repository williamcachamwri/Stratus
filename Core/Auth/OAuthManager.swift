import Foundation
import AuthenticationServices
import CryptoKit
import os.log

// MARK: - OAuthTokens

public struct OAuthTokens: Sendable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?
    public let tokenType: String

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        expiresAt: Date,
        scope: String? = nil,
        tokenType: String = "Bearer"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }
}

// MARK: - OAuthError

public enum OAuthError: Error, Sendable {
    case userCancelled
    case noAuthorizationCode
    case stateMismatch
    case pkceVerifierMissing
    case tokenExchangeFailed(statusCode: Int, body: String)
    case invalidTokenResponse(String)
    case refreshFailed(statusCode: Int, body: String)
    case missingRefreshToken
    case sessionCreationFailed(any Error)
}

// MARK: - OAuthManager

/// ASWebAuthenticationSession-based OAuth 2.0 with PKCE (RFC 7636).
///
/// Manages the full OAuth lifecycle:
///  1. Build the authorization URL (including code_challenge).
///  2. Present the system browser via ASWebAuthenticationSession.
///  3. Exchange the authorization code for tokens.
///  4. Refresh tokens using the refresh_token grant.
public actor OAuthManager: NSObject {
    public static let shared = OAuthManager()

    private let session = URLSession(configuration: .ephemeral)
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "OAuthManager")

    // Pending PKCE verifiers keyed by state nonce
    private var pendingVerifiers: [String: String] = [:]

    private override init() {}

    // MARK: - Authenticate

    /// Launches the system browser for the OAuth 2.0 Authorization Code flow
    /// with PKCE and returns the resulting tokens.
    ///
    /// - Parameters:
    ///   - provider: Human-readable provider name used for logging.
    ///   - clientID: OAuth client identifier registered with the provider.
    ///   - redirectURI: The URI the provider will redirect to after authorization.
    ///   - scopes: OAuth scopes to request.
    ///   - authorizationURL: The provider's authorization endpoint.
    ///   - tokenURL: The provider's token endpoint.
    public func authenticate(
        provider: String,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        authorizationURL: URL,
        tokenURL: URL
    ) async throws -> OAuthTokens {
        // Generate PKCE pair
        let verifier = generateCodeVerifier()
        let challenge = codeChallenge(from: verifier)
        let state = generateState()

        // Store verifier to validate when the redirect arrives
        pendingVerifiers[state] = verifier

        guard let redirectURL = URL(string: redirectURI) else {
            throw OAuthError.sessionCreationFailed(URLError(.badURL))
        }

        let authURL = buildAuthorizationURL(
            base: authorizationURL,
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: scopes,
            state: state,
            codeChallenge: challenge
        )

        logger.info("Starting OAuth flow for provider: \(provider)")

        // Present ASWebAuthenticationSession on the main actor
        let callbackURL = try await presentAuthSession(
            url: authURL,
            callbackScheme: redirectURL.scheme ?? "stratus"
        )

        // Parse callback
        let (code, returnedState) = try extractCodeAndState(from: callbackURL)

        // Validate state to prevent CSRF
        guard returnedState == state else {
            pendingVerifiers.removeValue(forKey: state)
            throw OAuthError.stateMismatch
        }

        guard let storedVerifier = pendingVerifiers.removeValue(forKey: state) else {
            throw OAuthError.pkceVerifierMissing
        }

        // Exchange code for tokens
        let tokens = try await exchangeCode(
            code: code,
            verifier: storedVerifier,
            clientID: clientID,
            redirectURI: redirectURI,
            tokenURL: tokenURL
        )

        logger.info("OAuth flow completed for provider: \(provider)")
        return tokens
    }

    // MARK: - Refresh

    /// Exchanges a refresh token for a new set of tokens.
    public func refresh(
        tokens: OAuthTokens,
        clientID: String,
        tokenURL: URL
    ) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw OAuthError.missingRefreshToken
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
        ]

        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw OAuthError.invalidTokenResponse("Could not encode refresh request body")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.refreshFailed(statusCode: 0, body: "")
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token refresh failed (\(http.statusCode)): \(body)")
            throw OAuthError.refreshFailed(statusCode: http.statusCode, body: body)
        }

        return try parseTokenResponse(data: data, fallbackRefreshToken: refreshToken)
    }

    // MARK: - Private: PKCE

    private func generateCodeVerifier() -> String {
        // RFC 7636 §4.1: 43–128 chars from [A-Z a-z 0-9 - . _ ~]
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private func codeChallenge(from verifier: String) -> String {
        // S256 method: BASE64URL(SHA256(ASCII(code_verifier)))
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64URLEncodedString()
    }

    private func generateState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    // MARK: - Private: URL Building

    private func buildAuthorizationURL(
        base: URL,
        clientID: String,
        redirectURI: String,
        scopes: [String],
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) ?? URLComponents()
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        components.queryItems = items
        return components.url ?? base
    }

    // MARK: - Private: ASWebAuthenticationSession

    @MainActor
    private func presentAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let authSession = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callbackURL, error in
                if let error {
                    if let authError = error as? ASWebAuthenticationSessionError,
                       authError.code == .canceledLogin {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.sessionCreationFailed(error))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.noAuthorizationCode)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            authSession.prefersEphemeralWebBrowserSession = true
            authSession.start()
        }
    }

    // MARK: - Private: Callback Parsing

    private func extractCodeAndState(from url: URL) throws -> (code: String, state: String) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []

        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.noAuthorizationCode
        }
        guard let state = items.first(where: { $0.name == "state" })?.value else {
            throw OAuthError.stateMismatch
        }
        return (code, state)
    }

    // MARK: - Private: Token Exchange

    private func exchangeCode(
        code: String,
        verifier: String,
        clientID: String,
        redirectURI: String,
        tokenURL: URL
    ) async throws -> OAuthTokens {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]

        guard let body = components.percentEncodedQuery?.data(using: .utf8) else {
            throw OAuthError.invalidTokenResponse("Could not encode token exchange body")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed(statusCode: 0, body: "")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            logger.error("Token exchange failed (\(http.statusCode)): \(body)")
            throw OAuthError.tokenExchangeFailed(statusCode: http.statusCode, body: body)
        }

        return try parseTokenResponse(data: data, fallbackRefreshToken: nil)
    }

    private func parseTokenResponse(data: Data, fallbackRefreshToken: String?) throws -> OAuthTokens {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String
        else {
            throw OAuthError.invalidTokenResponse("Missing access_token in response")
        }

        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let refreshToken = json["refresh_token"] as? String ?? fallbackRefreshToken
        let scope = json["scope"] as? String
        let tokenType = json["token_type"] as? String ?? "Bearer"

        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn),
            scope: scope,
            tokenType: tokenType
        )
    }
}

// MARK: - Data+Base64URL

private extension Data {
    /// URL-safe Base64 without padding (RFC 7636 §4.2).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
