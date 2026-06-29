import Foundation
import os.log

public actor DropboxProvider: CloudProvider {
    public nonisolated let id = "dropbox"
    public nonisolated let displayName = "Dropbox"
    public nonisolated let iconName = "dropbox"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: true,
        supportsParallelChunks: false,  // Dropbox upload sessions are sequential
        maxChunkSize: 150 * 1024 * 1024,
        minChunkSize: 1,
        maxConcurrentUploads: 5,
        supportsVersioning: true,
        supportsTrash: true,
        supportsDeltaSync: false,
        multipartThresholdBytes: 4 * 1024 * 1024
    )

    private let chunkedUpload = DropboxChunkedUpload()
    private let vault = CredentialVault.shared
    private let http = HTTPClient()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DropboxProvider")

    public init() {}

    public func authenticate(account: CloudAccount) async throws {
        guard try await vault.loadOAuthCredential(providerID: id, accountID: account.id) != nil else {
            throw ProviderError.authenticationFailed("No OAuth credential stored.")
        }
    }
    public func refreshCredentials(account: CloudAccount) async throws {}
    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let cred = try await vault.loadOAuthCredential(providerID: id, accountID: account.id) else { return false }
        let request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!,
                                  method: .POST, headers: ["Authorization": "Bearer \(cred.accessToken)"])
        let response = try await http.data(for: request)
        return response.isSuccess
    }
    public func revokeCredentials(account: CloudAccount) async throws {
        try await vault.deleteOAuthCredential(providerID: id, accountID: account.id)
    }

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        let token = try await accessToken(account: account)
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_space_usage")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let used = json["used"] as? Int64,
              let allocation = json["allocation"] as? [String: Any],
              let total = allocation["allocated"] as? Int64 else {
            return StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
        }
        return StorageQuota(totalBytes: total, usedBytes: used, availableBytes: total - used)
    }

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        let token = try await accessToken(account: account)
        let body: [String: Any] = pageToken == nil
            ? ["path": path.path == "/" ? "" : path.path, "recursive": false, "limit": 1000]
            : [:]
        let url = pageToken == nil
            ? URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
            : URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
        var request = HTTPRequest(url: url, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = pageToken == nil
            ? try JSONSerialization.data(withJSONObject: body)
            : try JSONSerialization.data(withJSONObject: ["cursor": pageToken!])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse("Failed to parse Dropbox list")
        }
        let items = entries.map { entry -> CloudFileItem in
            let isDir = (entry[".tag"] as? String) == "folder"
            return CloudFileItem(
                id: (entry["id"] as? String) ?? "",
                name: (entry["name"] as? String) ?? "",
                path: path.appendingComponent((entry["name"] as? String) ?? ""),
                size: entry["size"] as? Int64,
                isDirectory: isDir,
                etag: entry["content_hash"] as? String
            )
        }
        let hasMore = json["has_more"] as? Bool ?? false
        let cursor = json["cursor"] as? String
        return PagedResult(items: items, nextPageToken: hasMore ? cursor : nil)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_metadata")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["path": path.path])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ProviderError.fileNotFound(path)
        }
        let isDir = (json[".tag"] as? String) == "folder"
        return CloudFileItem(id: (json["id"] as? String) ?? "", name: (json["name"] as? String) ?? "",
                              path: path, size: json["size"] as? Int64, isDirectory: isDir,
                              etag: json["content_hash"] as? String)
    }

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        let token = try await accessToken(account: account)
        return try await chunkedUpload.startSession(accessToken: token)
    }

    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        let token = try await accessToken(account: account)
        let offset = Int64(chunkNumber - 1) * Int64(50 * 1024 * 1024)
        try await chunkedUpload.appendChunk(sessionID: uploadID, data: data, offset: offset, isLast: false, accessToken: token)
        return ChunkUploadResult(etag: nil)
    }

    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let totalOffset = parts.reduce(0) { $0 + Int64($1.partNumber) }
        let id = try await chunkedUpload.finishSession(sessionID: uploadID, offset: totalOffset, remotePath: "/", accessToken: token)
        return CloudFileItem(id: id, name: "", path: CloudPath("/"))
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        var request = HTTPRequest(url: URL(string: "https://content.dropboxapi.com/2/files/upload")!, method: .POST)
        let apiArg = "{\"path\":\"\(remotePath.path)\",\"mode\":\"overwrite\"}"
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Dropbox-API-Arg"] = apiArg
        request.headers["Content-Type"] = "application/octet-stream"
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
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["path": path.path])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let link = json["link"] as? String, let url = URL(string: link) else {
            throw ProviderError.invalidResponse("No download link")
        }
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
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/files/create_folder_v2")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["path": path.path])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any],
              let id = metadata["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: id, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/files/move_v2")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["from_path": from.path, "to_path": to.path])
        let response = try await http.data(for: request)
        guard response.isSuccess else { throw ProviderError.serverError(statusCode: response.statusCode, message: "") }
        return CloudFileItem(id: "", name: to.lastComponent, path: to)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/files/copy_v2")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["from_path": from.path, "to_path": to.path])
        let response = try await http.data(for: request)
        guard response.isSuccess else { throw ProviderError.serverError(statusCode: response.statusCode, message: "") }
        return CloudFileItem(id: "", name: to.lastComponent, path: to)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        let token = try await accessToken(account: account)
        var request = HTTPRequest(url: URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = try JSONSerialization.data(withJSONObject: ["path": path.path])
        let response = try await http.data(for: request)
        guard response.isSuccess else { throw ProviderError.serverError(statusCode: response.statusCode, message: "") }
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        try await move(from: path, to: path.deletingLastComponent.appendingComponent(newName), account: account)
    }

    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? {
        let item = try await fileMetadata(path: path, account: account)
        guard let etag = item.etag else { return nil }
        return RemoteChecksum(algorithm: .sha256, value: etag)  // Dropbox uses content_hash (SHA-256 based)
    }

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
        let url = try await downloadURL(path: path, account: account, expiresIn: options.expiresAt?.timeIntervalSinceNow ?? 3600)
        return ShareLink(url: url, expiresAt: options.expiresAt, id: UUID().uuidString)
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
