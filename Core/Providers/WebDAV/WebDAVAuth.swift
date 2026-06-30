import CryptoKit
import Foundation
import os.log

// MARK: - WebDAVAuthMethod

public enum WebDAVAuthMethod: Sendable {
    case basic(username: String, password: String)
    case digest(username: String, password: String)
    case oauth2(token: String)
}

// MARK: - WebDAVAuthError

public enum WebDAVAuthError: Error, Sendable {
    case unsupportedAuthScheme(String)
    case missingDigestChallenge
    case malformedChallenge(String)
    case noAuthMethodAvailable
}

// MARK: - WebDAVAuth

// Handles WebDAV authentication: Basic, Digest (RFC 7616), and OAuth2 Bearer.
// Call `authorizationHeader` to get the header value for a request.
// Call `handleChallenge` when the server returns a 401 to negotiate a method.

public actor WebDAVAuth {
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "WebDAVAuth")

    /// The currently active authentication method.
    private var currentMethod: WebDAVAuthMethod?

    /// Digest state — nonce counter incremented per request.
    private var digestNonceCount: Int = 0
    /// Last parsed digest challenge parameters.
    private var digestChallenge: DigestChallenge?

    public init(initialMethod: WebDAVAuthMethod? = nil) {
        currentMethod = initialMethod
    }

    // MARK: - Authorization Header

    /// Returns the `Authorization` header value for the given URL and HTTP method.
    /// Throws `WebDAVAuthError.noAuthMethodAvailable` if no method has been configured.
    public func authorizationHeader(for url: URL, method: String) async throws -> String {
        guard let authMethod = currentMethod else {
            throw WebDAVAuthError.noAuthMethodAvailable
        }

        switch authMethod {
        case let .basic(username, password):
            return basicHeader(username: username, password: password)

        case let .digest(username, password):
            return try digestHeader(username: username, password: password, url: url, method: method)

        case let .oauth2(token):
            return "Bearer \(token)"
        }
    }

    // MARK: - Challenge Handling

    /// Parses the `WWW-Authenticate` header from a 401 response and returns
    /// the negotiated auth method. Also updates internal state ready for the
    /// next call to `authorizationHeader`.
    public func handleChallenge(from response: HTTPURLResponse) async throws -> WebDAVAuthMethod {
        guard let header = response.allHeaderFields["WWW-Authenticate"] as? String else {
            throw WebDAVAuthError.missingDigestChallenge
        }

        let trimmed = header.trimmingCharacters(in: .whitespaces)

        if trimmed.lowercased().hasPrefix("bearer") {
            // OAuth2 Bearer challenge — caller must supply token externally;
            // keep current method if it is already oauth2
            if case let .oauth2(token) = currentMethod {
                return .oauth2(token: token)
            }
            throw WebDAVAuthError.unsupportedAuthScheme("Bearer (no token available)")
        }

        if trimmed.lowercased().hasPrefix("digest") {
            let challenge = try parseDigestChallenge(from: trimmed)
            digestChallenge = challenge
            digestNonceCount = 0
            logger.debug("WebDAV Digest challenge received, realm: \(challenge.realm)")
            // Preserve username/password from current method if it is Digest or Basic
            switch currentMethod {
            case let .digest(u, p), let .basic(u, p):
                let method = WebDAVAuthMethod.digest(username: u, password: p)
                currentMethod = method
                return method
            default:
                throw WebDAVAuthError.noAuthMethodAvailable
            }
        }

        if trimmed.lowercased().hasPrefix("basic") {
            switch currentMethod {
            case let .basic(u, p):
                return .basic(username: u, password: p)
            default:
                throw WebDAVAuthError.unsupportedAuthScheme("Basic (no credentials available)")
            }
        }

        throw WebDAVAuthError.unsupportedAuthScheme(trimmed)
    }

    // MARK: - Update Method

    /// Replaces the active authentication method.
    public func setMethod(_ method: WebDAVAuthMethod) {
        currentMethod = method
    }

    // MARK: - Private: Basic

    private func basicHeader(username: String, password: String) -> String {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    // MARK: - Private: Digest

    private func digestHeader(
        username: String,
        password: String,
        url: URL,
        method: String
    ) throws -> String {
        guard let challenge = digestChallenge else {
            // Fallback to Basic if no digest challenge has been received yet
            return basicHeader(username: username, password: password)
        }

        digestNonceCount += 1
        let nc = String(format: "%08x", digestNonceCount)
        let cnonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let uri = url.path.isEmpty ? "/" : url.path

        let ha1 = md5Hex("\(username):\(challenge.realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")
        let response = md5Hex("\(ha1):\(challenge.nonce):\(nc):\(cnonce):auth:\(ha2)")

        var header = "Digest username=\"\(username)\""
        header += ", realm=\"\(challenge.realm)\""
        header += ", nonce=\"\(challenge.nonce)\""
        header += ", uri=\"\(uri)\""
        header += ", qop=auth"
        header += ", nc=\(nc)"
        header += ", cnonce=\"\(cnonce)\""
        header += ", response=\"\(response)\""
        if let opaque = challenge.opaque {
            header += ", opaque=\"\(opaque)\""
        }
        return header
    }

    private func md5Hex(_ input: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Private: Digest Challenge Parsing

    private struct DigestChallenge {
        let realm: String
        let nonce: String
        let opaque: String?
        let algorithm: String
        let qop: String?
    }

    private func parseDigestChallenge(from header: String) throws -> DigestChallenge {
        // Strip "Digest " prefix
        let body = header.dropFirst("Digest ".count)

        func extract(_ key: String) -> String? {
            guard let range = body.range(of: "\(key)=\"", options: .caseInsensitive) else { return nil }
            let valueStart = body[range.upperBound...]
            guard let endQuote = valueStart.firstIndex(of: "\"") else { return nil }
            return String(valueStart[..<endQuote])
        }

        guard let realm = extract("realm"),
              let nonce = extract("nonce")
        else {
            throw WebDAVAuthError.malformedChallenge("Missing realm or nonce in Digest challenge")
        }

        return DigestChallenge(
            realm: realm,
            nonce: nonce,
            opaque: extract("opaque"),
            algorithm: extract("algorithm") ?? "MD5",
            qop: extract("qop")
        )
    }
}
