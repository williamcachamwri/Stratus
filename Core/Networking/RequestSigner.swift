import Foundation
import CryptoKit

// MARK: - AWS SigV4 Request Signer

public struct RequestSigner: Sendable {

    // MARK: - SigV4

    public static func signV4(
        request: inout URLRequest,
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        region: String,
        service: String,
        date: Date = Date()
    ) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateTimeString = formatter.string(from: date)
        let dateString = String(dateTimeString.prefix(8))

        // Required headers
        request.setValue(dateTimeString, forHTTPHeaderField: "x-amz-date")
        if let host = request.url?.host {
            request.setValue(host, forHTTPHeaderField: "Host")
        }
        if let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        // Payload hash
        let body = request.httpBody ?? Data()
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        request.setValue(bodyHash, forHTTPHeaderField: "x-amz-content-sha256")

        // Canonical request
        let method = request.httpMethod ?? "GET"
        let uri = canonicalURI(from: request.url)
        let queryString = canonicalQueryString(from: request.url)
        let sortedHeaders = sortedSignedHeaders(from: request)
        let canonicalHeaders = sortedHeaders.map { "\($0.key):\($0.value)\n" }.joined()
        let signedHeaderNames = sortedHeaders.map { $0.key }.joined(separator: ";")

        let canonicalRequest = [method, uri, queryString, canonicalHeaders, signedHeaderNames, bodyHash].joined(separator: "\n")

        // String to sign
        let credentialScope = "\(dateString)/\(region)/\(service)/aws4_request"
        let canonicalHash = SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined()
        let stringToSign = ["AWS4-HMAC-SHA256", dateTimeString, credentialScope, canonicalHash].joined(separator: "\n")

        // Signing key
        let signingKey = deriveSigningKey(secretKey: secretAccessKey, date: dateString, region: region, service: service)

        // Signature
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey)
            .map { String(format: "%02x", $0) }.joined()

        // Authorization header
        let authorization = "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(credentialScope), SignedHeaders=\(signedHeaderNames), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Presigned URL (query-string signature)

    public static func presignedURL(
        url: URL,
        method: String = "GET",
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil,
        region: String,
        service: String,
        expiresIn: TimeInterval = 3600,
        date: Date = Date()
    ) -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let dateTimeString = formatter.string(from: date)
        let dateString = String(dateTimeString.prefix(8))
        let credentialScope = "\(dateString)/\(region)/\(service)/aws4_request"
        let credential = "\(accessKeyID)/\(credentialScope)"

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var queryItems = components.queryItems ?? []
        queryItems += [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: credential),
            URLQueryItem(name: "X-Amz-Date", value: dateTimeString),
            URLQueryItem(name: "X-Amz-Expires", value: String(Int(expiresIn))),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]
        if let token = sessionToken {
            queryItems.append(URLQueryItem(name: "X-Amz-Security-Token", value: token))
        }
        components.queryItems = queryItems.sorted { $0.name < $1.name }

        guard let presignURL = components.url else { return nil }
        let uri = canonicalURI(from: presignURL)
        let queryString = canonicalQueryString(from: presignURL)
        let host = presignURL.host ?? ""
        let canonicalRequest = [method, uri, queryString, "host:\(host)\n", "host", "UNSIGNED-PAYLOAD"].joined(separator: "\n")
        let canonicalHash = SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined()
        let stringToSign = ["AWS4-HMAC-SHA256", dateTimeString, credentialScope, canonicalHash].joined(separator: "\n")
        let signingKey = deriveSigningKey(secretKey: secretAccessKey, date: dateString, region: region, service: service)
        let signature = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: signingKey)
            .map { String(format: "%02x", $0) }.joined()

        components.queryItems?.append(URLQueryItem(name: "X-Amz-Signature", value: signature))
        return components.url
    }

    // MARK: - Private

    private static func deriveSigningKey(secretKey: String, date: String, region: String, service: String) -> SymmetricKey {
        let kDate = HMAC<SHA256>.authenticationCode(for: Data(date.utf8), using: SymmetricKey(data: Data(("AWS4" + secretKey).utf8)))
        let kRegion = HMAC<SHA256>.authenticationCode(for: Data(region.utf8), using: SymmetricKey(data: kDate))
        let kService = HMAC<SHA256>.authenticationCode(for: Data(service.utf8), using: SymmetricKey(data: kRegion))
        let kSigning = HMAC<SHA256>.authenticationCode(for: Data("aws4_request".utf8), using: SymmetricKey(data: kService))
        return SymmetricKey(data: kSigning)
    }

    private static func canonicalURI(from url: URL?) -> String {
        let path = url?.path ?? "/"
        return path.isEmpty ? "/" : path
    }

    private static func canonicalQueryString(from url: URL?) -> String {
        guard let comps = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              let items = comps.queryItems, !items.isEmpty else { return "" }
        return items
            .sorted { $0.name < $1.name }
            .map { "\($0.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.name)=\(($0.value ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
    }

    private static func sortedSignedHeaders(from request: URLRequest) -> [(key: String, value: String)] {
        let excluded = Set(["connection", "user-agent"])
        var headers: [(key: String, value: String)] = []
        for (key, value) in (request.allHTTPHeaderFields ?? [:]) {
            let lower = key.lowercased()
            if !excluded.contains(lower) {
                headers.append((key: lower, value: value.trimmingCharacters(in: .whitespaces)))
            }
        }
        return headers.sorted { $0.key < $1.key }
    }
}
