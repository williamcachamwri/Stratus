import Foundation
import os.log

// MARK: - FTPSMode

public enum FTPSMode: Sendable {
    /// Explicit FTPS: connects on standard FTP port (21) then upgrades via AUTH TLS.
    case explicit
    /// Implicit FTPS: wraps the entire connection in TLS from the start (port 990).
    case implicit
}

// MARK: - FTPSProvider

// FTPS provider (FTP over TLS). Explicit and implicit TLS modes.
// Delegates to FTPProvider configured with TLS enabled.
// All methods currently surface ProviderError.unsupportedOperation as the
// underlying URLSession FTP implementation handles TLS transparently through
// the ftps:// scheme — a full FTPS stack would replace these stubs.

public actor FTPSProvider: CloudProvider {
    public nonisolated let id = "ftps"
    public nonisolated let displayName = "FTPS"
    public nonisolated let iconName = "server.rack"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: false,
        supportsParallelChunks: false,
        maxChunkSize: 64 * 1024 * 1024,
        minChunkSize: 1,
        maxConcurrentUploads: 2,
        multipartThresholdBytes: Int.max
    )

    public let ftpsMode: FTPSMode

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "FTPSProvider")

    public init(mode: FTPSMode = .explicit) {
        ftpsMode = mode
    }

    // MARK: - Auth

    public func authenticate(account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    public func refreshCredentials(account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        throw ProviderError.unsupportedOperation("")
    }

    public func revokeCredentials(account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Quota

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Listing

    public func listDirectory(
        path: CloudPath,
        account: CloudAccount,
        pageToken: String?
    ) async throws -> PagedResult<[CloudFileItem]> {
        throw ProviderError.unsupportedOperation("")
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Multipart Upload

    public func initiateMultipartUpload(
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> String {
        throw ProviderError.unsupportedOperation("")
    }

    public func uploadChunk(
        uploadID: String,
        chunkNumber: Int,
        data: Data,
        account: CloudAccount
    ) async throws -> ChunkUploadResult {
        throw ProviderError.unsupportedOperation("")
    }

    public func completeMultipartUpload(
        uploadID: String,
        parts: [CompletedPart],
        account: CloudAccount
    ) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Small File Upload

    public func uploadSmallFile(
        data: Data,
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Download

    public func downloadURL(
        path: CloudPath,
        account: CloudAccount,
        expiresIn: TimeInterval
    ) async throws -> URL {
        throw ProviderError.unsupportedOperation("")
    }

    public func downloadRange(
        path: CloudPath,
        range: ClosedRange<Int64>,
        account: CloudAccount
    ) async throws -> Data {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - File Operations

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Checksums & Manifests

    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? {
        throw ProviderError.unsupportedOperation("")
    }

    public nonisolated var supportsBlockManifest: Bool {
        false
    }

    public func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? {
        throw ProviderError.unsupportedOperation("")
    }

    public func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Trash

    public func trash(path: CloudPath, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    public func listTrash(account: CloudAccount) async throws -> [CloudFileItem] {
        throw ProviderError.unsupportedOperation("")
    }

    public func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    public func emptyTrash(account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Versioning

    public func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] {
        throw ProviderError.unsupportedOperation("")
    }

    public func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Sharing

    public func createShareLink(
        path: CloudPath,
        account: CloudAccount,
        options: ShareOptions
    ) async throws -> ShareLink {
        throw ProviderError.unsupportedOperation("")
    }

    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {
        throw ProviderError.unsupportedOperation("")
    }

    // MARK: - Streaming

    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        throw ProviderError.unsupportedOperation("")
    }
}
