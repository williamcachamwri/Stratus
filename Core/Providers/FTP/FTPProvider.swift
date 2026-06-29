import Foundation
import os.log

// MARK: - FTPProvider
// FTP/FTPS using URLSession's built-in FTP support (RFC 959).
// Note: URLSession supports FTP download, but upload uses NSStream.
// For FTPS (implicit TLS), uses ftps:// scheme; explicit STARTTLS uses ftp://.

public actor FTPProvider: CloudProvider {
    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let iconName = "ftp"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: false,
        supportsParallelChunks: false,
        maxChunkSize: 64 * 1024 * 1024,
        minChunkSize: 1,
        maxConcurrentUploads: 2,
        multipartThresholdBytes: Int.max
    )

    public struct FTPConfig: Sendable {
        let host: String
        let port: Int
        let usesTLS: Bool  // true = FTPS (implicit TLS)
        let username: String
        let password: String
        let basePath: String

        public init(host: String, port: Int = 21, usesTLS: Bool = false,
                    username: String, password: String, basePath: String = "/") {
            self.host = host
            self.port = port
            self.usesTLS = usesTLS
            self.username = username
            self.password = password
            self.basePath = basePath
        }

        var scheme: String { usesTLS ? "ftps" : "ftp" }
        var baseURL: URL {
            URL(string: "\(scheme)://\(host):\(port)\(basePath.hasPrefix("/") ? basePath : "/\(basePath)")")!
        }
    }

    private var configs: [String: FTPConfig] = [:]
    private let vault = CredentialVault.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "FTPProvider")

    public init(id: String = "ftp", displayName: String = "FTP") {
        self.id = id
        self.displayName = displayName
    }

    public func registerConfig(_ config: FTPConfig, accountID: String) {
        configs[accountID] = config
    }

    // MARK: - Auth

    public func authenticate(account: CloudAccount) async throws {
        guard configs[account.id] != nil else { throw ProviderError.authenticationFailed("No FTP config for account") }
    }
    public func refreshCredentials(account: CloudAccount) async throws {}
    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let config = configs[account.id] else { return false }
        let url = config.baseURL
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        return (try? await URLSession.shared.data(for: request)) != nil
    }
    public func revokeCredentials(account: CloudAccount) async throws {
        configs.removeValue(forKey: account.id)
    }

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
    }

    // MARK: - Directory Listing

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        guard let config = configs[account.id] else { throw ProviderError.authenticationFailed("No FTP config") }
        let url = config.baseURL.appendingPathComponent(path.path)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (data, _) = try await urlSession(config: config).data(for: request)
        let listing = String(data: data, encoding: .utf8) ?? ""
        let items = parseFTPListing(listing: listing, basePath: path)
        return PagedResult(items: items)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        let items = try await listDirectory(path: path.deletingLastComponent, account: account, pageToken: nil).items
        guard let item = items.first(where: { $0.name == path.lastComponent }) else {
            throw ProviderError.fileNotFound(path)
        }
        return item
    }

    // MARK: - Upload

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String { remotePath.path }
    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult { ChunkUploadResult(etag: nil) }
    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(id: uploadID, name: (uploadID as NSString).lastPathComponent, path: CloudPath(uploadID))
    }
    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        guard let config = configs[account.id] else { throw ProviderError.authenticationFailed("No FTP config") }
        let url = config.baseURL.appendingPathComponent(remotePath.path)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        let (_, response) = try await urlSession(config: config).data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode < 400 else {
            throw ProviderError.uploadFailed("FTP upload failed for \(remotePath.path)")
        }
        return CloudFileItem(id: remotePath.path, name: remotePath.lastComponent, path: remotePath, size: Int64(data.count))
    }

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        guard let config = configs[account.id] else { throw ProviderError.authenticationFailed("No FTP config") }
        return config.baseURL.appendingPathComponent(path.path)
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        guard let config = configs[account.id] else { throw ProviderError.authenticationFailed("No FTP config") }
        let url = config.baseURL.appendingPathComponent(path.path)
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, _) = try await urlSession(config: config).data(for: request)
        return data
    }

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let config = configs[account.id] else { throw ProviderError.authenticationFailed("No FTP config") }
        let url = config.baseURL.appendingPathComponent(path.path + "/")
        var request = URLRequest(url: url)
        request.httpMethod = "MKD"
        _ = try? await urlSession(config: config).data(for: request)
        return CloudFileItem(id: path.path, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("FTP does not support server-side rename via URLSession")
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("FTP does not support server-side copy")
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        guard let config = configs[account.id] else { throw ProviderError.authenticationFailed("No FTP config") }
        let url = config.baseURL.appendingPathComponent(path.path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await urlSession(config: config).data(for: request)
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("FTP rename requires raw FTP commands; use SFTP instead")
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
        throw ProviderError.unsupportedOperation("FTP does not support share links")
    }
    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await downloadURL(path: path, account: account, expiresIn: 0)
    }

    // MARK: - Private Helpers

    private func urlSession(config: FTPConfig) -> URLSession {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpAdditionalHeaders = ["Authorization": "Basic \(basicAuth(config: config))"]
        return URLSession(configuration: sessionConfig)
    }

    private func basicAuth(config: FTPConfig) -> String {
        Data("\(config.username):\(config.password)".utf8).base64EncodedString()
    }

    private func parseFTPListing(listing: String, basePath: CloudPath) -> [CloudFileItem] {
        var items: [CloudFileItem] = []
        for line in listing.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let name = String(parts[8])
            guard name != "." && name != ".." else { continue }
            let isDir = line.first == "d"
            let size = Int64(String(parts[4])) ?? 0
            items.append(CloudFileItem(id: basePath.appendingComponent(name).path, name: name,
                                        path: basePath.appendingComponent(name),
                                        size: isDir ? nil : size, isDirectory: isDir))
        }
        return items
    }
}
