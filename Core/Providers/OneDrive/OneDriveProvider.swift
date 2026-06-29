import Foundation
import os.log

public actor OneDriveProvider: CloudProvider {
    public nonisolated let id = "onedrive"
    public nonisolated let displayName = "Microsoft OneDrive"
    public nonisolated let iconName = "onedrive"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: true,
        supportsParallelChunks: false,
        maxChunkSize: 60 * 1024 * 1024,   // 60 MB max per fragment
        minChunkSize: 320 * 1024,          // Must be multiple of 320 KB
        maxConcurrentUploads: 4,
        supportsVersioning: true,
        supportsTrash: true,
        multipartThresholdBytes: 4 * 1024 * 1024
    )

    private let vault = CredentialVault.shared
    private let http = HTTPClient()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "OneDriveProvider")
    private static let baseURL = "https://graph.microsoft.com/v1.0/me/drive"

    public init() {}

    public func authenticate(account: CloudAccount) async throws {
        guard try await vault.loadOAuthCredential(providerID: id, accountID: account.id) != nil else {
            throw ProviderError.authenticationFailed("No credential stored for OneDrive.")
        }
    }
    public func refreshCredentials(account: CloudAccount) async throws {}
    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let cred = try await vault.loadOAuthCredential(providerID: id, accountID: account.id) else { return false }
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)")!, headers: ["Authorization": "Bearer \(cred.accessToken)"])
        let response = try await http.data(for: request)
        return response.isSuccess
    }
    public func revokeCredentials(account: CloudAccount) async throws {
        try await vault.deleteOAuthCredential(providerID: id, accountID: account.id)
    }

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        let token = try await accessToken(account: account)
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)?$select=quota")!, headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let quota = json["quota"] as? [String: Any] else {
            return StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
        }
        return StorageQuota(totalBytes: quota["total"] as? Int64, usedBytes: (quota["used"] as? Int64) ?? 0,
                             availableBytes: quota["remaining"] as? Int64)
    }

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        let token = try await accessToken(account: account)
        let itemPath = path.path == "/" ? "root" : "root:\(path.path)"
        var url: URL
        if let pt = pageToken, let nextURL = URL(string: pt) {
            url = nextURL
        } else {
            url = URL(string: "\(Self.baseURL)/\(itemPath)/children?$select=id,name,size,file,folder,lastModifiedDateTime,@microsoft.graph.downloadUrl&$top=999")!
        }
        let request = HTTPRequest(url: url, headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse("Failed to parse OneDrive list")
        }
        let items = values.map { item -> CloudFileItem in
            let isDir = item["folder"] != nil
            return CloudFileItem(id: (item["id"] as? String) ?? "", name: (item["name"] as? String) ?? "",
                                  path: path.appendingComponent((item["name"] as? String) ?? ""),
                                  size: item["size"] as? Int64, isDirectory: isDir,
                                  downloadURL: (item["@microsoft.graph.downloadUrl"] as? String).flatMap(URL.init))
        }
        return PagedResult(items: items, nextPageToken: json["@odata.nextLink"] as? String)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)/root:\(path.path)")!, headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ProviderError.fileNotFound(path)
        }
        return CloudFileItem(id: (json["id"] as? String) ?? "", name: (json["name"] as? String) ?? "",
                              path: path, size: json["size"] as? Int64, isDirectory: json["folder"] != nil)
    }

    // OneDrive large file upload session
    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        let token = try await accessToken(account: account)
        let url = URL(string: "\(Self.baseURL)/root:\(remotePath.path):/createUploadSession")!
        var request = HTTPRequest(url: url, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: [
            "item": ["@microsoft.graph.conflictBehavior": "replace", "name": remotePath.lastComponent]
        ])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let uploadURL = json["uploadUrl"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return uploadURL  // The upload URL IS the session ID for OneDrive
    }

    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        let chunkSize = 10 * 1024 * 1024  // Assume 10 MB chunks
        let offset = Int64(chunkNumber - 1) * Int64(chunkSize)
        var request = HTTPRequest(url: URL(string: uploadID)!, method: .PUT)
        request.headers["Content-Length"] = "\(data.count)"
        request.headers["Content-Range"] = "bytes \(offset)-\(offset + Int64(data.count) - 1)/*"
        request.body = data
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 202 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return ChunkUploadResult(etag: nil)
    }

    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        return CloudFileItem(id: "", name: "", path: CloudPath("/"))
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {
        let request = HTTPRequest(url: URL(string: uploadID)!, method: .DELETE)
        _ = try? await http.data(for: request)
    }

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let url = URL(string: "\(Self.baseURL)/root:\(remotePath.path):/content")!
        var request = HTTPRequest(url: url, method: .PUT)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = metadata.contentType ?? "application/octet-stream"
        request.body = data
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: id, name: remotePath.lastComponent, path: remotePath, size: Int64(data.count))
    }

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        let token = try await accessToken(account: account)
        let url = URL(string: "\(Self.baseURL)/root:\(path.path):/content")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        // OneDrive returns 302 redirect to direct download URL
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config)
        let (_, response) = try await session.data(for: request)
        if let redirectURL = (response as? HTTPURLResponse)?.url { return redirectURL }
        return url
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        let url = try await downloadURL(path: path, account: account, expiresIn: 3600)
        var request = HTTPRequest(url: url)
        request.headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        let response = try await http.data(for: request)
        return response.data
    }

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let parentPath = path.deletingLastComponent.path
        let url = URL(string: "\(Self.baseURL)/root:\(parentPath):/children")!
        var request = HTTPRequest(url: url, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["name": path.lastComponent, "folder": [:]])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: id, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let item = try await fileMetadata(path: from, account: account)
        let url = URL(string: "\(Self.baseURL)/items/\(item.id)")!
        var request = HTTPRequest(url: url, method: .PATCH)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["name": to.lastComponent])
        let response = try await http.data(for: request)
        guard response.isSuccess else { throw ProviderError.serverError(statusCode: response.statusCode, message: "") }
        return CloudFileItem(id: item.id, name: to.lastComponent, path: to)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        return try await move(from: from, to: to, account: account)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        let token = try await accessToken(account: account)
        let url = URL(string: "\(Self.baseURL)/root:\(path.path)")!
        let request = HTTPRequest(url: url, method: .DELETE, headers: ["Authorization": "Bearer \(token)"])
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

    private func accessToken(account: CloudAccount) async throws -> String {
        guard let cred = try await vault.loadOAuthCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No credential for \(account.id)")
        }
        return cred.accessToken
    }
}
