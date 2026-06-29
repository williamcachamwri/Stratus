import Foundation
import AuthenticationServices
import CryptoKit

public actor OneDriveAuth {
    public static let shared = OneDriveAuth()
    private static let authURL = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    private static let tokenURL = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    private static let redirectURI = "com.stratus.cloudmanager://auth/onedrive"
    private static let scope = "Files.ReadWrite.All offline_access"
    private init() {}

    public func authorize(clientID: String, context: ASWebAuthenticationPresentationContextProviding) async throws -> OAuthCredential {
        let (verifier, challenge) = generatePKCE()
        var comps = URLComponents(string: Self.authURL)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query"),
        ]
        let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, any Error>) in
            let session = ASWebAuthenticationSession(url: comps.url!, callbackURLScheme: "com.stratus.cloudmanager") { url, error in
                if let error { cont.resume(throwing: error) }
                else if let url { cont.resume(returning: url) }
                else { cont.resume(throwing: AuthError.cancelled) }
            }
            session.presentationContextProvider = context
            session.prefersEphemeralWebBrowserSession = true
            session.start()
        }
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AuthError.noAuthorizationCode
        }
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "client_id=\(clientID)&redirect_uri=\(Self.redirectURI)&grant_type=authorization_code&code=\(code)&code_verifier=\(verifier)&scope=\(Self.scope)"
        request.httpBody = Data(body.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else { throw AuthError.invalidTokenResponse }
        return OAuthCredential(accessToken: accessToken, refreshToken: json["refresh_token"] as? String,
                                expiresAt: Date().addingTimeInterval((json["expires_in"] as? TimeInterval) ?? 3600))
    }

    private func generatePKCE() -> (String, String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let v = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let c = Data(SHA256.hash(data: Data(v.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return (v, c)
    }
}
