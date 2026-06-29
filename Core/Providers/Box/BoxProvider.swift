import Foundation
import os.log

// MARK: - BoxProvider
// Box Content API v2 — https://developer.box.com/reference

public actor BoxProvider: CloudProvider {
    public nonisolated let id = "box"
    public nonisolated let displayName = "Box"
    public nonisolated let iconName = "box"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: true,
        supportsResumeUpload: true,
        supportsParallelChunks: false,
        maxChunkSize: 50 * 1024 * 1024,
        minChunkSize: 1 * 1024 * 1024,
        maxConcurrentUploads: 6,
        multipartThresholdBytes: 50 * 1024 * 1024
    )

    private static let apiBase    = "https://api.box.com/2.0"
    private static let uploadBase = "https://upload.box.com/api/2.0"

    private let vault = CredentialVault.shared
    private let http = HTTPClient()
    private let refresher = TokenRefresher.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BoxProvider")

    public init() {}

    // MARK: - Auth

    public func authenticate(account: CloudAccount) async throws {}
    public func refreshCredentials(account: CloudAccount) async throws {
        _ = try await refresher.validToken(providerID: id, accountID: account.id)
    }
    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        (try? await currentUser(account: account)) != nil
    }
    public func revokeCredentials(account: CloudAccount) async throws {
        try await vault.deleteOAuthCredential(providerID: id, accountID: account.id)
    }

    // MARK: - Quota

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        let user = try await currentUser(account: account)
        let total = user["space_amount"] as? Int64 ?? 0
        let used  = user["space_used"] as? Int64 ?? 0
        return StorageQuota(totalBytes: total > 0 ? total : nil, usedBytes: used,
                             availableBytes: total > 0 ? total - used : nil)
    }

    private func currentUser(account: CloudAccount) async throws -> [String: Any] {
        let url = URL(string: "\(Self.apiBase)/users/me")!
        let response = try await http.data(for: HTTPRequest(url: url, headers: try await authHeaders(account: account)))
        return (try? JSONSerialization.jsonObject(with: response.data) as? [String: Any]) ?? [:]
    }

    // MARK: - Directory Listing

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        let folderID = path.path == "/" ? "0" : path.path
        var components = URLComponents(string: "\(Self.apiBase)/folders/\(folderID)/items")!
        components.queryItems = [
            .init(name: "fields", value: "id,name,type,size,modified_at,etag,sha1"),
            .init(name: "limit", value: "1000"),
        ]
        if let token = pageToken { components.queryItems?.append(.init(name: "marker", value: token)) }
        let response = try await http.data(for: HTTPRequest(url: components.url!, headers: try await authHeaders(account: account)))
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return PagedResult(items: []) }
        let items = entries.compactMap { parseItem($0, basePath: path) }
        let nextMarker = json["next_marker"] as? String
        return PagedResult(items: items, nextPageToken: nextMarker?.isEmpty == false ? nextMarker : nil)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let fileID = path.path
        let url = URL(string: "\(Self.apiBase)/files/\(fileID)?fields=id,name,type,size,modified_at,etag,sha1")!
        let response = try await http.data(for: HTTPRequest(url: url, headers: try await authHeaders(account: account)))
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ProviderError.fileNotFound(path)
        }
        return parseItem(json, basePath: path) ?? CloudFileItem(id: path.path, name: path.lastComponent, path: path)
    }

    // MARK: - Upload (chunked sessions for large files)

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        let parentID = "0"  // TODO: resolve from path
        let url = URL(string: "\(Self.uploadBase)/files/upload_sessions")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: [
            "folder_id": parentID,
            "file_name": remotePath.lastComponent,
            "file_size": metadata.fileSize as Any
        ])
        let request = HTTPRequest(url: url, method: .POST, headers: headers, body: body)
        let response = try await http.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let sessionID = json["id"] as? String else {
            throw ProviderError.uploadFailed("Failed to create Box upload session")
        }
        return sessionID
    }

    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        let url = URL(string: "\(Self.uploadBase)/files/upload_sessions/\(uploadID)")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/octet-stream"
        headers["Digest"] = "sha=\(data.sha1Base64())"
        let request = HTTPRequest(url: url, method: .PUT, headers: headers, body: data)
        let response = try await http.data(for: request)
        let etag = response.headers["Etag"]
        return ChunkUploadResult(etag: etag)
    }

    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        let url = URL(string: "\(Self.uploadBase)/files/upload_sessions/\(uploadID)/commit")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/json"
        let partsList = parts.map { ["part_id": $0.partNumber, "offset": 0, "size": 0] }
        let body = try JSONSerialization.data(withJSONObject: ["parts": partsList])
        let request = HTTPRequest(url: url, method: .POST, headers: headers, body: body)
        let response = try await http.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]],
              let file = entries.first else {
            throw ProviderError.uploadFailed("Box commit upload session failed")
        }
        return parseItem(file, basePath: CloudPath("/")) ?? CloudFileItem(id: uploadID, name: uploadID, path: CloudPath(uploadID))
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {
        let url = URL(string: "\(Self.uploadBase)/files/upload_sessions/\(uploadID)")!
        let request = HTTPRequest(url: url, method: .DELETE, headers: try await authHeaders(account: account))
        _ = try await http.data(for: request)
    }

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        let url = URL(string: "\(Self.uploadBase)/files/content")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "multipart/form-data; boundary=box_upload"
        let boundary = "box_upload"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"attributes\"\r\n\r\n".data(using: .utf8)!)
        let attrs = try JSONSerialization.data(withJSONObject: ["name": remotePath.lastComponent, "parent": ["id": "0"]])
        body.append(attrs)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(remotePath.lastComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        let request = HTTPRequest(url: url, method: .POST, headers: headers, body: body)
        let response = try await http.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let entries = (json["entries"] as? [[String: Any]])?.first else {
            throw ProviderError.uploadFailed("Box small upload failed")
        }
        return parseItem(entries, basePath: remotePath.deletingLastComponent) ?? CloudFileItem(id: "", name: remotePath.lastComponent, path: remotePath)
    }

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        let url = URL(string: "\(Self.apiBase)/files/\(path.path)/content")!
        let response = try await http.data(for: HTTPRequest(url: url, headers: try await authHeaders(account: account)))
        guard let location = response.headers["Location"], let downloadURL = URL(string: location) else {
            throw ProviderError.downloadFailed("Box did not return a download URL")
        }
        return downloadURL
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        let url = URL(string: "\(Self.apiBase)/files/\(path.path)/content")!
        var headers = try await authHeaders(account: account)
        headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        return try await http.data(for: HTTPRequest(url: url, headers: headers)).data
    }

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let url = URL(string: "\(Self.apiBase)/folders")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: ["name": path.lastComponent, "parent": ["id": "0"]])
        let response = try await http.data(for: HTTPRequest(url: url, method: .POST, headers: headers, body: body))
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let folderID = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: 0, message: "Failed to create Box folder")
        }
        return CloudFileItem(id: folderID, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let url = URL(string: "\(Self.apiBase)/files/\(from.path)")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: ["name": to.lastComponent, "parent": ["id": "0"]])
        let response = try await http.data(for: HTTPRequest(url: url, method: .PUT, headers: headers, body: body))
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ProviderError.serverError(statusCode: 0, message: "Box move failed")
        }
        return parseItem(json, basePath: to.deletingLastComponent) ?? CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let url = URL(string: "\(Self.apiBase)/files/\(from.path)/copy")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: ["name": to.lastComponent, "parent": ["id": "0"]])
        let response = try await http.data(for: HTTPRequest(url: url, method: .POST, headers: headers, body: body))
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ProviderError.serverError(statusCode: 0, message: "Box copy failed")
        }
        return parseItem(json, basePath: to.deletingLastComponent) ?? CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        let url = URL(string: "\(Self.apiBase)/files/\(path.path)")!
        _ = try await http.data(for: HTTPRequest(url: url, method: .DELETE, headers: try await authHeaders(account: account)))
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        try await move(from: path, to: path.deletingLastComponent.appendingComponent(newName), account: account)
    }

    public func trash(path: CloudPath, account: CloudAccount) async throws { try await delete(path: path, account: account) }
    public func listTrash(account: CloudAccount) async throws -> [CloudFileItem] { [] }
    public func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {}
    public func emptyTrash(account: CloudAccount) async throws {}
    public func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] { [] }
    public func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {}

    public func createShareLink(path: CloudPath, account: CloudAccount, options: ShareOptions) async throws -> ShareLink {
        let url = URL(string: "\(Self.apiBase)/shared_links/files/\(path.path)")!
        var headers = try await authHeaders(account: account)
        headers["Content-Type"] = "application/json"
        let shareAccess = options.allowPublicAccess ? "open" : "collaborators"
        let body = try JSONSerialization.data(withJSONObject: ["shared_link": ["access": shareAccess]])
        let response = try await http.data(for: HTTPRequest(url: url, method: .PUT, headers: headers, body: body))
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let link = (json["shared_link"] as? [String: Any])?["url"] as? String,
              let linkURL = URL(string: link) else {
            throw ProviderError.serverError(statusCode: 0, message: "Box share link failed")
        }
        return ShareLink(url: linkURL, id: link)
    }

    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? { nil }
    public nonisolated var supportsBlockManifest: Bool { false }
    public func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? { nil }
    public func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {}
    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await downloadURL(path: path, account: account, expiresIn: 3600)
    }

    // MARK: - Private

    private func authHeaders(account: CloudAccount) async throws -> [String: String] {
        let token = try await refresher.validToken(providerID: id, accountID: account.id)
        return ["Authorization": "Bearer \(token)"]
    }

    private func parseItem(_ json: [String: Any], basePath: CloudPath) -> CloudFileItem? {
        guard let itemID = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        let type = json["type"] as? String ?? "file"
        let isDir = type == "folder"
        let size = json["size"] as? Int64 ?? 0
        let etag = json["etag"] as? String
        return CloudFileItem(id: itemID, name: name, path: basePath.appendingComponent(name),
                              size: isDir ? nil : size, isDirectory: isDir, etag: etag)
    }
}

// MARK: - Data SHA1 helper

private extension Data {
    func sha1Base64() -> String {
        var digest = [UInt8](repeating: 0, count: 20)
        self.withUnsafeBytes { ptr in
            CC_SHA1(ptr.baseAddress, CC_LONG(count), &digest)
        }
        return Data(digest).base64EncodedString()
    }
}
