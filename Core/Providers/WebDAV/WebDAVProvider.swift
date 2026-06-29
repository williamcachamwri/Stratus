import Foundation
import os.log

public actor WebDAVProvider: CloudProvider {
    public nonisolated let id = "webdav"
    public nonisolated let displayName = "WebDAV"
    public nonisolated let iconName = "webdav"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: false,
        supportsParallelChunks: false,
        maxChunkSize: 256 * 1024 * 1024,
        minChunkSize: 1,
        maxConcurrentUploads: 4,
        multipartThresholdBytes: Int.max
    )

    private let vault = CredentialVault.shared
    private let http = HTTPClient()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "WebDAVProvider")

    // Base URL per account stored here
    private var baseURLs: [String: URL] = [:]

    public init() {}

    public func registerBaseURL(_ url: URL, accountID: String) {
        baseURLs[accountID] = url
    }

    public func authenticate(account: CloudAccount) async throws {
        guard baseURLs[account.id] != nil else { throw ProviderError.authenticationFailed("No WebDAV URL for account") }
    }
    public func refreshCredentials(account: CloudAccount) async throws {}
    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let base = baseURLs[account.id] else { return false }
        let response = try? await http.data(for: HTTPRequest(url: base, method: .HEAD, headers: await authHeaders(account: account)))
        return response?.isSuccess ?? false
    }
    public func revokeCredentials(account: CloudAccount) async throws {
        try await vault.deleteOAuthCredential(providerID: id, accountID: account.id)
        baseURLs.removeValue(forKey: account.id)
    }

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
    }

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let url = base.appendingPathComponent(path.path)
        var headers = await authHeaders(account: account)
        headers["Depth"] = "1"
        headers["Content-Type"] = "application/xml"
        let body = Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <propfind xmlns="DAV:"><prop><getcontentlength/><getlastmodified/><resourcetype/><getetag/></prop></propfind>
            """.utf8)

        var request = HTTPRequest(url: url, method: .POST, headers: headers, body: body)
        request.method = HTTPMethod(rawValue: "PROPFIND")!
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 207 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        let items = parseDAVResponse(data: response.data, basePath: path)
        return PagedResult(items: items)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let items = try await listDirectory(path: path.deletingLastComponent, account: account, pageToken: nil).items
        guard let item = items.first(where: { $0.name == path.lastComponent }) else {
            throw ProviderError.fileNotFound(path)
        }
        return item
    }

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        return remotePath.path
    }
    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        ChunkUploadResult(etag: nil)
    }
    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(id: uploadID, name: (uploadID as NSString).lastPathComponent, path: CloudPath(uploadID))
    }
    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let url = base.appendingPathComponent(remotePath.path)
        var headers = await authHeaders(account: account)
        headers["Content-Type"] = metadata.contentType ?? "application/octet-stream"
        let request = HTTPRequest(url: url, method: .PUT, headers: headers, body: data)
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 201 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        let etag = response.headers["ETag"]?.trimmingCharacters(in: .init(charactersIn: "\""))
        return CloudFileItem(id: remotePath.path, name: remotePath.lastComponent, path: remotePath,
                              size: Int64(data.count), etag: etag)
    }

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        return base.appendingPathComponent(path.path)
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let url = base.appendingPathComponent(path.path)
        var headers = await authHeaders(account: account)
        headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        let response = try await http.data(for: HTTPRequest(url: url, headers: headers))
        return response.data
    }

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let url = base.appendingPathComponent(path.path)
        var request = HTTPRequest(url: url, method: .POST, headers: await authHeaders(account: account))
        request.method = HTTPMethod(rawValue: "MKCOL")!
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 201 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: path.path, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let fromURL = base.appendingPathComponent(from.path)
        let toURL = base.appendingPathComponent(to.path)
        var headers = await authHeaders(account: account)
        headers["Destination"] = toURL.absoluteString
        headers["Overwrite"] = "T"
        var request = HTTPRequest(url: fromURL, method: .POST, headers: headers)
        request.method = HTTPMethod(rawValue: "MOVE")!
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 201 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let fromURL = base.appendingPathComponent(from.path)
        let toURL = base.appendingPathComponent(to.path)
        var headers = await authHeaders(account: account)
        headers["Destination"] = toURL.absoluteString
        headers["Overwrite"] = "T"
        var request = HTTPRequest(url: fromURL, method: .POST, headers: headers)
        request.method = HTTPMethod(rawValue: "COPY")!
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 201 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        guard let base = baseURLs[account.id] else { throw ProviderError.authenticationFailed("No WebDAV URL") }
        let url = base.appendingPathComponent(path.path)
        let request = HTTPRequest(url: url, method: .DELETE, headers: await authHeaders(account: account))
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 204 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        try await move(from: path, to: path.deletingLastComponent.appendingComponent(newName), account: account)
    }

    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? { nil }
    public nonisolated var supportsBlockManifest: Bool { false }
    public func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? { nil }
    public func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {}
    public func trash(path: CloudPath, account: CloudAccount) async throws { try await delete(path: path, account: account) }
    public func listTrash(account: CloudAccount) async throws -> [CloudFileItem] { [] }
    public func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {}
    public func emptyTrash(account: CloudAccount) async throws {}
    public func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] { [] }
    public func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {}
    public func createShareLink(path: CloudPath, account: CloudAccount, options: ShareOptions) async throws -> ShareLink {
        let url = try await downloadURL(path: path, account: account, expiresIn: 3600)
        return ShareLink(url: url, id: UUID().uuidString)
    }
    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await downloadURL(path: path, account: account, expiresIn: 86400)
    }

    // MARK: - Private

    private func authHeaders(account: CloudAccount) async -> [String: String] {
        if let cred = try? await vault.loadBasicCredential(providerID: id, accountID: account.id) {
            let data = "\(cred.username):\(cred.password)".data(using: .utf8)!
            return ["Authorization": "Basic \(data.base64EncodedString())"]
        }
        if let cred = try? await vault.loadOAuthCredential(providerID: id, accountID: account.id) {
            return ["Authorization": "Bearer \(cred.accessToken)"]
        }
        return [:]
    }

    private func parseDAVResponse(data: Data, basePath: CloudPath) -> [CloudFileItem] {
        let xml = String(data: data, encoding: .utf8) ?? ""
        var items: [CloudFileItem] = []
        for response in xml.components(separatedBy: "<D:response>").dropFirst() {
            guard let href = response.components(separatedBy: "<D:href>").dropFirst().first?.components(separatedBy: "</D:href>").first else { continue }
            let name = (href.removingPercentEncoding ?? href).components(separatedBy: "/").filter { !$0.isEmpty }.last ?? ""
            guard !name.isEmpty else { continue }
            let isDir = response.contains("<D:collection/>")
            let sizeStr = response.components(separatedBy: "<D:getcontentlength>").dropFirst().first?.components(separatedBy: "</D:getcontentlength>").first ?? "0"
            let size = Int64(sizeStr) ?? 0
            let etag = response.components(separatedBy: "<D:getetag>").dropFirst().first?.components(separatedBy: "</D:getetag>").first?.trimmingCharacters(in: .init(charactersIn: "\""))
            items.append(CloudFileItem(id: href, name: name, path: basePath.appendingComponent(name),
                                        size: isDir ? nil : size, isDirectory: isDir, etag: etag))
        }
        return items
    }
}
