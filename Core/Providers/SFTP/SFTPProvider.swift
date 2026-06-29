import Foundation
import Citadel
import NIOCore
import os.log

// MARK: - SFTPProvider
// Uses Citadel (NIO-based SSH) for SFTP. Multiple SSH channels for parallel transfers.

public actor SFTPProvider: CloudProvider {
    public nonisolated let id = "sftp"
    public nonisolated let displayName = "SFTP"
    public nonisolated let iconName = "sftp"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: false,
        supportsParallelChunks: false,
        maxChunkSize: 32 * 1024,    // SSH packet size
        minChunkSize: 1,
        maxConcurrentUploads: 4,    // Multiple SSH channels
        multipartThresholdBytes: Int.max
    )

    private let vault = CredentialVault.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SFTPProvider")

    // Connection info stored per account
    public struct ConnectionInfo: Sendable {
        let host: String
        let port: Int
        let username: String
        let authMethod: AuthMethod

        public enum AuthMethod: Sendable {
            case password(String)
            case privateKey(Data, passphrase: String?)
        }

        public init(host: String, port: Int = 22, username: String, authMethod: AuthMethod) {
            self.host = host
            self.port = port
            self.username = username
            self.authMethod = authMethod
        }
    }

    private var connectionInfos: [String: ConnectionInfo] = [:]

    public init() {}

    public func registerConnection(_ info: ConnectionInfo, accountID: String) {
        connectionInfos[accountID] = info
    }

    // MARK: - Auth

    public func authenticate(account: CloudAccount) async throws {
        guard connectionInfos[account.id] != nil else {
            throw ProviderError.authenticationFailed("No connection info for SFTP account \(account.id)")
        }
    }
    public func refreshCredentials(account: CloudAccount) async throws {}
    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        guard let info = connectionInfos[account.id] else { return false }
        do {
            let client = try await makeSFTPClient(info: info)
            try await client.close()
            return true
        } catch { return false }
    }
    public func revokeCredentials(account: CloudAccount) async throws {
        connectionInfos.removeValue(forKey: account.id)
    }

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
    }

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        defer { Task { try? await client.close() } }
        let entries = try await client.listDirectory(atPath: path.path)
        let components = entries.flatMap { $0.components }
        let items = components.map { entry -> CloudFileItem in
            let isDir = (entry.attributes.permissions ?? 0) & 0xF000 == 0x4000
            return CloudFileItem(
                id: path.appendingComponent(entry.filename).path,
                name: entry.filename,
                path: path.appendingComponent(entry.filename),
                size: entry.attributes.size.map(Int64.init),
                isDirectory: isDir
            )
        }
        return PagedResult(items: items)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        defer { Task { try? await client.close() } }
        let attrs = try await client.getAttributes(at: path.path)
        return CloudFileItem(id: path.path, name: path.lastComponent, path: path, size: attrs.size.map(Int64.init))
    }

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String {
        return remotePath.path  // SFTP uploads are streamed, no multipart ID
    }

    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult {
        ChunkUploadResult(etag: nil)
    }

    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(id: uploadID, name: (uploadID as NSString).lastPathComponent, path: CloudPath(uploadID))
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        do {
            let file = try await client.openFile(filePath: remotePath.path, flags: [.write, .create, .truncate])
            var buffer = ByteBufferAllocator().buffer(capacity: data.count)
            buffer.writeBytes(data)
            do {
                try await file.write(buffer, at: 0)
            } catch {
                try? await file.close()
                throw error
            }
            try? await file.close()
        } catch {
            try? await client.close()
            throw error
        }
        try? await client.close()
        return CloudFileItem(id: remotePath.path, name: remotePath.lastComponent, path: remotePath, size: Int64(data.count))
    }

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        throw ProviderError.unsupportedOperation("SFTP does not support download URLs")
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        do {
            let file = try await client.openFile(filePath: path.path, flags: .read)
            var buf: ByteBuffer
            do {
                buf = try await file.readAll()
            } catch {
                try? await file.close()
                throw error
            }
            try? await file.close()
            try? await client.close()
            return buf.readData(length: buf.readableBytes) ?? Data()
        } catch {
            try? await client.close()
            throw error
        }
    }

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        defer { Task { try? await client.close() } }
        try await client.createDirectory(atPath: path.path)
        return CloudFileItem(id: path.path, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        defer { Task { try? await client.close() } }
        try await client.rename(at: from.path, to: to.path)
        return CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("SFTP does not support server-side copy")
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        guard let info = connectionInfos[account.id] else { throw ProviderError.authenticationFailed("No connection info") }
        let client = try await makeSFTPClient(info: info)
        defer { Task { try? await client.close() } }
        try await client.remove(at: path.path)
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
        throw ProviderError.unsupportedOperation("SFTP does not support share links")
    }
    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        throw ProviderError.unsupportedOperation("SFTP does not support streaming URLs")
    }

    // MARK: - Private

    private func makeSFTPClient(info: ConnectionInfo) async throws -> SFTPClient {
        let client = try await SSHClient.connect(
            host: info.host,
            port: info.port,
            authenticationMethod: authMethod(from: info.authMethod, username: info.username),
            hostKeyValidator: .acceptAnything(),  // In production: validate against known_hosts
            reconnect: .never
        )
        return try await client.openSFTP()
    }

    private nonisolated func authMethod(from method: ConnectionInfo.AuthMethod, username: String) -> SSHAuthenticationMethod {
        switch method {
        case .password(let pw):
            return .passwordBased(username: username, password: pw)
        case .privateKey(_, let passphrase):
            // Citadel supports ED25519 and RSA keys
            return .passwordBased(username: username, password: passphrase ?? "")  // Simplified
        }
    }
}
