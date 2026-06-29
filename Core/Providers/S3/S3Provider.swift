import Foundation
import CryptoKit
import os.log

// MARK: - S3 Configuration

public struct S3Configuration: Sendable {
    public let endpoint: URL          // https://s3.amazonaws.com or custom
    public let region: String
    public let bucket: String
    public let useTransferAcceleration: Bool
    public let usePathStyleURL: Bool   // true for MinIO, Ceph, etc.

    public init(
        endpoint: URL? = nil,
        region: String = "us-east-1",
        bucket: String,
        useTransferAcceleration: Bool = false,
        usePathStyleURL: Bool = false
    ) {
        if let ep = endpoint {
            self.endpoint = ep
        } else if useTransferAcceleration {
            self.endpoint = URL(string: "https://\(bucket).s3-accelerate.amazonaws.com")!
        } else {
            self.endpoint = URL(string: "https://s3.\(region).amazonaws.com")!
        }
        self.region = region
        self.bucket = bucket
        self.useTransferAcceleration = useTransferAcceleration
        self.usePathStyleURL = usePathStyleURL
    }
}

// MARK: - S3Provider
// Handles AWS S3, Wasabi, Backblaze B2, Cloudflare R2, MinIO, Ceph.

public actor S3Provider: CloudProvider {
    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let iconName: String
    public nonisolated let capabilities: ProviderCapabilities

    private let config: S3Configuration
    private let http = HTTPClient()
    private let credentialVault = CredentialVault.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "S3Provider")

    public init(id: String = "s3", displayName: String = "Amazon S3",
                iconName: String = "s3", config: S3Configuration) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.config = config
        self.capabilities = ProviderCapabilities(
            supportsMultipartUpload: true,
            supportsResumeUpload: true,
            supportsParallelChunks: true,
            maxChunkSize: 5 * 1024 * 1024 * 1024,
            minChunkSize: 5 * 1024 * 1024,
            maxConcurrentUploads: 32,
            supportsTransferAcceleration: true,
            supportsVersioning: true,
            supportsTrash: false,
            supportsBlockManifest: true,
            supportsDeltaSync: true,
            supportsCRC32c: false,
            supportsSHA256ETag: true,
            supportsServerSideCopy: true,
            maxFileSizeBytes: 5 * 1024 * 1024 * 1024 * 1024,  // 5 TB
            multipartThresholdBytes: 5 * 1024 * 1024
        )
    }

    // MARK: - Authentication

    public func authenticate(account: CloudAccount) async throws {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials found for \(account.id)")
        }
        _ = try await validateCredentials(account: account)
        logger.info("S3 authenticated for account \(account.id)")
    }

    public func refreshCredentials(account: CloudAccount) async throws {
        // S3 static credentials don't expire; STS tokens handled separately
    }

    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            return false
        }
        var request = URLRequest(url: bucketURL())
        request.httpMethod = "HEAD"
        RequestSigner.signV4(
            request: &request,
            accessKeyID: cred.accessKeyID,
            secretAccessKey: cred.secretAccessKey,
            sessionToken: cred.sessionToken,
            region: config.region,
            service: "s3"
        )
        let response = try await http.data(for: HTTPRequest(url: request.url!, method: .HEAD, headers: request.allHTTPHeaderFields ?? [:]))
        return response.isSuccess || response.statusCode == 403  // 403 = bucket exists, no list permission
    }

    public func revokeCredentials(account: CloudAccount) async throws {
        try await credentialVault.deleteOAuthCredential(providerID: id, accountID: account.id)
    }

    // MARK: - Quota

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        // S3 has no quota API; return unlimited
        return StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
    }

    // MARK: - File Listing

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let prefix = path.path == "/" ? "" : String(path.path.dropFirst())
        var components = URLComponents(url: bucketURL(), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "delimiter", value: "/"),
            URLQueryItem(name: "prefix", value: prefix),
            URLQueryItem(name: "max-keys", value: "1000"),
        ]
        if let token = pageToken {
            components.queryItems?.append(URLQueryItem(name: "continuation-token", value: token))
        }
        var request = URLRequest(url: components.url!)
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")

        let response = try await http.data(for: HTTPRequest(url: request.url!, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.isSuccess else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: String(data: response.data, encoding: .utf8) ?? "")
        }

        let (items, nextToken) = try parseListResponse(data: response.data, bucket: config.bucket)
        return PagedResult(items: items, nextPageToken: nextToken)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = String(path.path.dropFirst())
        let url = objectURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")

        let response = try await http.data(for: HTTPRequest(url: url, method: .HEAD, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.isSuccess else {
            if response.statusCode == 404 { throw ProviderError.fileNotFound(path) }
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }

        let size = Int64(response.headers["Content-Length"] ?? response.headers["content-length"] ?? "0") ?? 0
        return CloudFileItem(id: key, name: path.lastComponent, path: path, size: size,
                              contentType: response.headers["Content-Type"],
                              etag: response.headers["ETag"]?.trimmingCharacters(in: .init(charactersIn: "\"")))
    }

    // MARK: - Multipart Upload

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = String(remotePath.path.dropFirst())
        let url = objectURL(key: key, query: "uploads")
        var headers: [String: String] = ["Content-Type": metadata.contentType ?? "application/octet-stream"]
        if let ctype = metadata.contentType { headers["Content-Type"] = ctype }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")

        let response = try await http.data(for: HTTPRequest(url: url, method: .POST, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.isSuccess else {
            throw mapS3Error(response)
        }
        return try parseUploadID(from: response.data)
    }

    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = ""  // Would be stored in session in real impl
        let url = objectURL(key: key, query: "partNumber=\(chunkNumber)&uploadId=\(uploadID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadID)")

        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let md5Base64 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")

        let response = try await http.upload(
            request: HTTPRequest(url: url, method: .PUT, headers: request.allHTTPHeaderFields ?? [:]),
            from: data
        )
        guard response.isSuccess else { throw mapS3Error(response) }
        let etag = response.headers["ETag"]?.trimmingCharacters(in: .init(charactersIn: "\""))
        return ChunkUploadResult(etag: etag, serverConfirmedChecksum: true)
    }

    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = ""
        let url = objectURL(key: key, query: "uploadId=\(uploadID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadID)")

        let xmlParts = parts.map { "<Part><PartNumber>\($0.partNumber)</PartNumber><ETag>\($0.etag)</ETag></Part>" }.joined()
        let body = Data("<CompleteMultipartUpload>\(xmlParts)</CompleteMultipartUpload>".utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")

        let response = try await http.upload(
            request: HTTPRequest(url: url, method: .POST, headers: request.allHTTPHeaderFields ?? [:]),
            from: body
        )
        guard response.isSuccess else { throw mapS3Error(response) }
        return CloudFileItem(id: key, name: (key as NSString).lastPathComponent, path: CloudPath(key))
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else { return }
        let key = ""
        let url = objectURL(key: key, query: "uploadId=\(uploadID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uploadID)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")
        _ = try? await http.data(for: HTTPRequest(url: url, method: .DELETE, headers: request.allHTTPHeaderFields ?? [:]))
    }

    // MARK: - Small File Upload

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = String(remotePath.path.dropFirst())
        let url = objectURL(key: key)
        let md5Base64 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")
        request.setValue(metadata.contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")

        let response = try await http.upload(
            request: HTTPRequest(url: url, method: .PUT, headers: request.allHTTPHeaderFields ?? [:]),
            from: data
        )
        guard response.isSuccess else { throw mapS3Error(response) }
        return CloudFileItem(id: key, name: remotePath.lastComponent, path: remotePath, size: Int64(data.count))
    }

    // MARK: - Download

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = String(path.path.dropFirst())
        let url = objectURL(key: key)
        guard let presigned = RequestSigner.presignedURL(
            url: url, accessKeyID: cred.accessKeyID, secretAccessKey: cred.secretAccessKey,
            sessionToken: cred.sessionToken, region: config.region, service: "s3", expiresIn: min(expiresIn, 604800)
        ) else { throw ProviderError.invalidResponse("Failed to generate presigned URL") }
        return presigned
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = String(path.path.dropFirst())
        let url = objectURL(key: key)
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")
        let response = try await http.data(for: HTTPRequest(url: url, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.statusCode == 206 || response.isSuccess else { throw mapS3Error(response) }
        return response.data
    }

    // MARK: - File Operations

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        // S3 has no real directories — create zero-byte key with trailing slash
        return try await uploadSmallFile(data: Data(), remotePath: CloudPath(path.path + "/"), account: account, metadata: UploadMetadata())
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let item = try await copy(from: from, to: to, account: account)
        try await delete(path: from, account: account)
        return item
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let destKey = String(to.path.dropFirst())
        let sourceKey = "/\(config.bucket)/\(String(from.path.dropFirst()))"
        let url = objectURL(key: destKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(sourceKey, forHTTPHeaderField: "x-amz-copy-source")
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")
        let response = try await http.data(for: HTTPRequest(url: url, method: .PUT, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.isSuccess else { throw mapS3Error(response) }
        return CloudFileItem(id: destKey, name: to.lastComponent, path: to)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credentials")
        }
        let key = String(path.path.dropFirst())
        let url = objectURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")
        let response = try await http.data(for: HTTPRequest(url: url, method: .DELETE, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.isSuccess || response.statusCode == 204 else { throw mapS3Error(response) }
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        let newPath = path.deletingLastComponent.appendingComponent(newName)
        return try await move(from: path, to: newPath, account: account)
    }

    // MARK: - Checksums

    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? {
        let item = try await fileMetadata(path: path, account: account)
        guard let etag = item.etag, !etag.contains("-") else { return nil }  // skip multipart ETags
        return RemoteChecksum(algorithm: .md5, value: etag)
    }

    // MARK: - Block Manifest (for delta sync via xattr-like metadata)

    public nonisolated var supportsBlockManifest: Bool { true }

    public func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? {
        guard let cred = try await credentialVault.loadAPIKeyCredential(providerID: id, accountID: account.id) else { return nil }
        let manifestKey = String(path.path.dropFirst()) + ".stratus_manifest"
        let url = objectURL(key: manifestKey)
        var request = URLRequest(url: url)
        RequestSigner.signV4(request: &request, accessKeyID: cred.accessKeyID,
                              secretAccessKey: cred.secretAccessKey, sessionToken: cred.sessionToken,
                              region: config.region, service: "s3")
        let response = try await http.data(for: HTTPRequest(url: url, headers: request.allHTTPHeaderFields ?? [:]))
        guard response.isSuccess else { return nil }
        return try? JSONDecoder().decode(BlockMap.self, from: response.data)
    }

    public func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {
        let data = try JSONEncoder().encode(manifest)
        let manifestPath = CloudPath(path.path + ".stratus_manifest")
        _ = try await uploadSmallFile(data: data, remotePath: manifestPath, account: account,
                                       metadata: UploadMetadata(contentType: "application/json"))
    }

    // MARK: - Unsupported (S3 has no trash/versions in base impl)

    public func trash(path: CloudPath, account: CloudAccount) async throws { try await delete(path: path, account: account) }
    public func listTrash(account: CloudAccount) async throws -> [CloudFileItem] { [] }
    public func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {}
    public func emptyTrash(account: CloudAccount) async throws {}
    public func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] { [] }
    public func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {}

    public func createShareLink(path: CloudPath, account: CloudAccount, options: ShareOptions) async throws -> ShareLink {
        let url = try await downloadURL(path: path, account: account, expiresIn: options.expiresAt.map { $0.timeIntervalSinceNow } ?? 3600)
        return ShareLink(url: url, expiresAt: options.expiresAt, id: UUID().uuidString)
    }

    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}

    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await downloadURL(path: path, account: account, expiresIn: 86400)
    }

    // MARK: - URL Helpers

    private func bucketURL() -> URL {
        if config.usePathStyleURL {
            return config.endpoint.appendingPathComponent(config.bucket)
        }
        var comps = URLComponents(url: config.endpoint, resolvingAgainstBaseURL: false)!
        comps.host = "\(config.bucket).\(comps.host ?? "")"
        return comps.url ?? config.endpoint
    }

    private func objectURL(key: String, query: String? = nil) -> URL {
        let base = config.usePathStyleURL
            ? config.endpoint.appendingPathComponent(config.bucket).appendingPathComponent(key)
            : bucketURL().appendingPathComponent(key)
        if let query {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            comps.query = query
            return comps.url ?? base
        }
        return base
    }

    // MARK: - Error Mapping

    private func mapS3Error(_ response: HTTPResponse) -> ProviderError {
        let body = String(data: response.data, encoding: .utf8) ?? ""
        switch response.statusCode {
        case 403: return .accessDenied(body)
        case 404: return .fileNotFound(CloudPath("/"))
        case 409 where body.contains("NoSuchUpload"): return .sessionExpired
        case 429: return .rateLimited(retryAfter: response.retryAfter() ?? 30)
        case 503 where body.contains("SlowDown"): return .rateLimited(retryAfter: 1)
        default: return .serverError(statusCode: response.statusCode, message: body)
        }
    }

    // MARK: - XML Parsing

    private func parseListResponse(data: Data, bucket: String) throws -> ([CloudFileItem], String?) {
        // Simple XML parsing without external lib
        let xml = String(data: data, encoding: .utf8) ?? ""
        var items: [CloudFileItem] = []
        var nextToken: String? = nil

        // Parse CommonPrefixes (directories)
        for match in xml.components(separatedBy: "<CommonPrefixes>").dropFirst() {
            if let prefix = match.components(separatedBy: "<Prefix>").dropFirst().first?.components(separatedBy: "</Prefix>").first {
                let name = (prefix as NSString).lastPathComponent.trimmingCharacters(in: .init(charactersIn: "/"))
                items.append(CloudFileItem(id: prefix, name: name, path: CloudPath(prefix), isDirectory: true))
            }
        }

        // Parse Contents (files)
        for match in xml.components(separatedBy: "<Contents>").dropFirst() {
            let keyMatch = match.components(separatedBy: "<Key>").dropFirst().first?.components(separatedBy: "</Key>").first ?? ""
            let sizeStr = match.components(separatedBy: "<Size>").dropFirst().first?.components(separatedBy: "</Size>").first ?? "0"
            let etag = match.components(separatedBy: "<ETag>").dropFirst().first?.components(separatedBy: "</ETag>").first?.trimmingCharacters(in: .init(charactersIn: "\"&quot;"))
            let size = Int64(sizeStr) ?? 0
            let name = (keyMatch as NSString).lastPathComponent
            items.append(CloudFileItem(id: keyMatch, name: name, path: CloudPath(keyMatch), size: size, etag: etag))
        }

        // Next continuation token
        if let tokenMatch = xml.components(separatedBy: "<NextContinuationToken>").dropFirst().first?.components(separatedBy: "</NextContinuationToken>").first {
            nextToken = tokenMatch
        }

        return (items, nextToken)
    }

    private func parseUploadID(from data: Data) throws -> String {
        let xml = String(data: data, encoding: .utf8) ?? ""
        guard let uploadID = xml.components(separatedBy: "<UploadId>").dropFirst().first?.components(separatedBy: "</UploadId>").first else {
            throw ProviderError.invalidResponse("No UploadId in response")
        }
        return uploadID
    }
}
