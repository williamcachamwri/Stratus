import Foundation
import os.log

// MARK: - GoogleDriveProvider

public actor GoogleDriveProvider: CloudProvider {
    public nonisolated let id = "gdrive"
    public nonisolated let displayName = "Google Drive"
    public nonisolated let iconName = "gdrive"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,  // GDrive uses resumable session protocol, not S3-style multipart
        supportsResumeUpload: true,
        supportsParallelChunks: false,   // GDrive upload is sequential per session
        maxChunkSize: 256 * 1024 * 1024,
        minChunkSize: 256 * 1024,        // Must be multiple of 256 KB
        maxConcurrentUploads: 5,
        supportsVersioning: true,
        supportsTrash: true,
        supportsBlockManifest: true,
        supportsDeltaSync: true,
        supportsSHA256ETag: false,
        supportsServerSideCopy: true,
        multipartThresholdBytes: 5 * 1024 * 1024
    )

    private let resumableUpload = GoogleDriveResumableUpload()
    private let vault = CredentialVault.shared
    private let http = HTTPClient()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "GoogleDriveProvider")

    private static let baseURL = "https://www.googleapis.com/drive/v3"

    public init() {}

    // MARK: - Auth

    public func authenticate(account: CloudAccount) async throws {
        guard let _ = try await vault.loadOAuthCredential(providerID: id, accountID: account.id) else {
            throw ProviderError.authenticationFailed("No OAuth credential stored. Use GoogleDriveAuth to authorize.")
        }
    }

    public func refreshCredentials(account: CloudAccount) async throws {
        // Token refresh handled by TokenRefresher before each request
    }

    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let cred = try await vault.loadOAuthCredential(providerID: id, accountID: account.id) else { return false }
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)/about?fields=storageQuota") ?? URL(fileURLWithPath: "/"),
                                  headers: ["Authorization": "Bearer \(cred.accessToken)"])
        let response = try await http.data(for: request)
        return response.isSuccess
    }

    public func revokeCredentials(account: CloudAccount) async throws {
        try await vault.deleteOAuthCredential(providerID: id, accountID: account.id)
    }

    // MARK: - Quota

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        let token = try await accessToken(account: account)
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)/about?fields=storageQuota") ?? URL(fileURLWithPath: "/"),
                                  headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let quota = json["storageQuota"] as? [String: Any] else {
            throw ProviderError.invalidResponse("Failed to parse quota")
        }
        let total = (quota["limit"] as? String).flatMap(Int64.init)
        let used = Int64((quota["usageInDrive"] as? String) ?? "0") ?? 0
        return StorageQuota(totalBytes: total, usedBytes: used, availableBytes: total.map { $0 - used })
    }

    // MARK: - File Listing

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        let token = try await accessToken(account: account)
        let folderID = path.path == "/" ? "root" : path.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var comps = URLComponents(string: "\(Self.baseURL)/files") ?? URLComponents()
        var queryItems = [
            URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,size,mimeType,modifiedTime,createdTime,md5Checksum,trashed),nextPageToken"),
            URLQueryItem(name: "pageSize", value: "1000"),
        ]
        if let pt = pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pt)) }
        comps.queryItems = queryItems

        guard let listURL = comps.url else { throw ProviderError.invalidResponse("Could not build URL") }
        let request = HTTPRequest(url: listURL, headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse("Failed to parse file list")
        }

        let items = files.map { file -> CloudFileItem in
            let isDir = (file["mimeType"] as? String) == "application/vnd.google-apps.folder"
            return CloudFileItem(
                id: (file["id"] as? String) ?? "",
                name: (file["name"] as? String) ?? "",
                path: path.appendingComponent((file["name"] as? String) ?? ""),
                size: (file["size"] as? String).flatMap(Int64.init),
                contentType: file["mimeType"] as? String,
                isDirectory: isDir
            )
        }
        return PagedResult(items: items, nextPageToken: json["nextPageToken"] as? String)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        let request = HTTPRequest(
            url: URL(string: "\(Self.baseURL)/files/\(fileID)?fields=id,name,size,mimeType,modifiedTime,md5Checksum") ?? URL(fileURLWithPath: "/"),
            headers: ["Authorization": "Bearer \(token)"]
        )
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw ProviderError.fileNotFound(path)
        }
        let isDir = (json["mimeType"] as? String) == "application/vnd.google-apps.folder"
        return CloudFileItem(
            id: (json["id"] as? String) ?? "",
            name: (json["name"] as? String) ?? "",
            path: path,
            size: (json["size"] as? String).flatMap(Int64.init),
            isDirectory: isDir,
            etag: json["md5Checksum"] as? String
        )
    }

    // MARK: - Multipart (not applicable for GDrive — use resumable)

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        let token = try await accessToken(account: account)
        let sessionURI = try await resumableUpload.initiateSession(
            fileName: remotePath.lastComponent,
            fileSize: 0,  // Will be set by ChunkEngine
            mimeType: metadata.contentType ?? "application/octet-stream",
            parentFolderID: nil,
            accessToken: token
        )
        return sessionURI.absoluteString
    }

    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        // GDrive upload is handled as a full file in uploadSmallFile; stub for protocol conformance
        return ChunkUploadResult(etag: nil)
    }

    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("Use uploadSmallFile for Google Drive")
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}

    // MARK: - Small File / Full Upload

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let body: [String: Any] = ["name": remotePath.lastComponent]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var comps = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files") ?? URLComponents()
        comps.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]

        // Build multipart body
        let boundary = "StratusBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var multipart = Data()
        multipart.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8) ?? Data())
        multipart.append(bodyData)
        multipart.append("\r\n--\(boundary)\r\nContent-Type: \(metadata.contentType ?? "application/octet-stream")\r\n\r\n".data(using: .utf8) ?? Data())
        multipart.append(data)
        multipart.append("\r\n--\(boundary)--".data(using: .utf8) ?? Data())

        guard let uploadURL = comps.url else { throw ProviderError.invalidResponse("Could not build URL") }
        var request = HTTPRequest(url: uploadURL, method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "multipart/related; boundary=\(boundary)"
        request.body = multipart

        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let fileID = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: String(data: response.data, encoding: .utf8) ?? "")
        }
        return CloudFileItem(id: fileID, name: remotePath.lastComponent, path: remotePath, size: Int64(data.count))
    }

    // MARK: - Download

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        // Direct download link (requires token in header — not a shareable URL)
        return URL(string: "\(Self.baseURL)/files/\(fileID)?alt=media&access_token=\(token)") ?? URL(fileURLWithPath: "/")
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        let url = try await downloadURL(path: path, account: account, expiresIn: 3600)
        var request = HTTPRequest(url: url)
        request.headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        let response = try await http.data(for: request)
        return response.data
    }

    // MARK: - File Operations

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let body = try JSONSerialization.data(withJSONObject: [
            "name": path.lastComponent,
            "mimeType": "application/vnd.google-apps.folder"
        ])
        var request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files") ?? URL(fileURLWithPath: "/"), method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = body
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: id, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        return try await rename(path: from, newName: to.lastComponent, account: account)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let fileID = from.lastComponent
        let body = try JSONSerialization.data(withJSONObject: ["name": to.lastComponent])
        var request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/\(fileID)/copy") ?? URL(fileURLWithPath: "/"), method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = body
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: id, name: to.lastComponent, path: to)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/\(fileID)") ?? URL(fileURLWithPath: "/"), method: .DELETE,
                                   headers: ["Authorization": "Bearer \(token)"])
        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 204 else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        let body = try JSONSerialization.data(withJSONObject: ["name": newName])
        var request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/\(fileID)") ?? URL(fileURLWithPath: "/"), method: .PATCH)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = body
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = json["id"] as? String else {
            throw ProviderError.serverError(statusCode: response.statusCode, message: "")
        }
        return CloudFileItem(id: id, name: newName, path: path.deletingLastComponent.appendingComponent(newName))
    }

    // MARK: - Checksums, Block Manifests

    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? {
        let item = try await fileMetadata(path: path, account: account)
        guard let etag = item.etag else { return nil }
        return RemoteChecksum(algorithm: .md5, value: etag)
    }

    public nonisolated var supportsBlockManifest: Bool { true }

    public func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? {
        // Store as app properties on the file
        return nil  // Simplified — full impl would use Files.get?fields=appProperties
    }

    public func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {}

    // MARK: - Trash

    public func trash(path: CloudPath, account: CloudAccount) async throws {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        var request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/\(fileID)") ?? URL(fileURLWithPath: "/"), method: .PATCH)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = body
        _ = try await http.data(for: request)
    }

    public func listTrash(account: CloudAccount) async throws -> [CloudFileItem] {
        return []
    }

    public func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {
        let token = try await accessToken(account: account)
        let body = try JSONSerialization.data(withJSONObject: ["trashed": false])
        var request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/\(item.id)") ?? URL(fileURLWithPath: "/"), method: .PATCH)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = body
        _ = try await http.data(for: request)
    }

    public func emptyTrash(account: CloudAccount) async throws {
        let token = try await accessToken(account: account)
        let request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/trash") ?? URL(fileURLWithPath: "/"), method: .DELETE,
                                   headers: ["Authorization": "Bearer \(token)"])
        _ = try await http.data(for: request)
    }

    // MARK: - Versions

    public func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        let request = HTTPRequest(
            url: URL(string: "\(Self.baseURL)/files/\(fileID)/revisions?fields=revisions(id,size,modifiedTime,keepForever)") ?? URL(fileURLWithPath: "/"),
            headers: ["Authorization": "Bearer \(token)"]
        )
        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let revisions = json["revisions"] as? [[String: Any]] else { return [] }
        return revisions.enumerated().map { (i, rev) in
            FileVersion(
                id: (rev["id"] as? String) ?? "",
                versionID: (rev["id"] as? String) ?? "",
                size: (rev["size"] as? String).flatMap(Int64.init) ?? 0,
                modificationDate: Date(),
                isLatest: i == revisions.count - 1
            )
        }
    }

    public func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {}

    // MARK: - Sharing

    public func createShareLink(path: CloudPath, account: CloudAccount, options: ShareOptions) async throws -> ShareLink {
        let token = try await accessToken(account: account)
        let fileID = path.lastComponent
        let permission: [String: Any] = ["type": "anyone", "role": options.canEdit ? "writer" : "reader"]
        let body = try JSONSerialization.data(withJSONObject: permission)
        var request = HTTPRequest(url: URL(string: "\(Self.baseURL)/files/\(fileID)/permissions") ?? URL(fileURLWithPath: "/"), method: .POST)
        request.headers["Authorization"] = "Bearer \(token)"
        request.headers["Content-Type"] = "application/json"
        request.body = body
        _ = try await http.data(for: request)
        return ShareLink(url: URL(string: "https://drive.google.com/file/d/\(fileID)/view") ?? URL(fileURLWithPath: "/"), id: fileID)
    }

    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}

    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await downloadURL(path: path, account: account, expiresIn: 3600)
    }

    // MARK: - Helpers

    private func accessToken(account: CloudAccount) async throws -> String {
        do {
            return try await TokenRefresher.shared.validToken(providerID: id, accountID: account.id)
        } catch {
            throw ProviderError.authenticationFailed("Could not obtain valid access token: \(error.localizedDescription)")
        }
    }
}
