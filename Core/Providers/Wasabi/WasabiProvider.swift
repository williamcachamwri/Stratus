import Foundation
import os.log

// MARK: - WasabiProvider

// Wasabi cloud storage accessed via the S3-compatible API.
// Endpoint: https://s3.<region>.wasabisys.com
//
// All CloudProvider methods are delegated to an internal S3Provider
// configured for the Wasabi endpoint.

public actor WasabiProvider: CloudProvider {
    // MARK: - CloudProvider Identity

    public nonisolated let id = "wasabi"
    public nonisolated let displayName = "Wasabi"
    public nonisolated let iconName = "wasabi"
    public nonisolated let capabilities: ProviderCapabilities

    // MARK: - Internals

    private let inner: S3Provider
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "WasabiProvider")

    // MARK: - Init

    /// Creates a `WasabiProvider` for the given bucket and region.
    ///
    /// - Parameters:
    ///   - bucket: Wasabi bucket name.
    ///   - region: Wasabi region, e.g. `"us-east-1"`, `"eu-central-1"`.
    public init(bucket: String, region: String = "us-east-1") {
        let provider = S3CompatibleProviders.wasabi(bucket: bucket, region: region)
        inner = provider
        capabilities = provider.capabilities
    }

    // MARK: - Authentication

    public func authenticate(account: CloudAccount) async throws {
        try await inner.authenticate(account: account)
    }

    public func refreshCredentials(account: CloudAccount) async throws {
        try await inner.refreshCredentials(account: account)
    }

    public func validateCredentials(account: CloudAccount) async throws -> Bool {
        try await inner.validateCredentials(account: account)
    }

    public func revokeCredentials(account: CloudAccount) async throws {
        try await inner.revokeCredentials(account: account)
    }

    // MARK: - Quota

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        try await inner.quota(for: account)
    }

    // MARK: - File Listing

    public func listDirectory(
        path: CloudPath,
        account: CloudAccount,
        pageToken: String?
    ) async throws -> PagedResult<[CloudFileItem]> {
        try await inner.listDirectory(path: path, account: account, pageToken: pageToken)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        try await inner.fileMetadata(path: path, account: account)
    }

    // MARK: - Multipart Upload

    public func initiateMultipartUpload(
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> String {
        try await inner.initiateMultipartUpload(remotePath: remotePath, account: account, metadata: metadata)
    }

    public func uploadChunk(
        uploadID: String,
        chunkNumber: Int,
        data: Data,
        account: CloudAccount
    ) async throws -> ChunkUploadResult {
        try await inner.uploadChunk(uploadID: uploadID, chunkNumber: chunkNumber, data: data, account: account)
    }

    public func completeMultipartUpload(
        uploadID: String,
        parts: [CompletedPart],
        account: CloudAccount
    ) async throws -> CloudFileItem {
        try await inner.completeMultipartUpload(uploadID: uploadID, parts: parts, account: account)
    }

    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {
        try await inner.abortMultipartUpload(uploadID: uploadID, account: account)
    }

    // MARK: - Small File Upload

    public func uploadSmallFile(
        data: Data,
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> CloudFileItem {
        try await inner.uploadSmallFile(data: data, remotePath: remotePath, account: account, metadata: metadata)
    }

    // MARK: - Download

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        try await inner.downloadURL(path: path, account: account, expiresIn: expiresIn)
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        try await inner.downloadRange(path: path, range: range, account: account)
    }

    // MARK: - File Operations

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        try await inner.createDirectory(path: path, account: account)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        try await inner.move(from: from, to: to, account: account)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        try await inner.copy(from: from, to: to, account: account)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        try await inner.delete(path: path, account: account)
    }

    public func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        try await inner.rename(path: path, newName: newName, account: account)
    }

    // MARK: - Checksums & Block Manifests

    public func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? {
        try await inner.remoteChecksum(path: path, account: account)
    }

    public nonisolated var supportsBlockManifest: Bool {
        true
    }

    public func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? {
        try await inner.fetchBlockManifest(path: path, account: account)
    }

    public func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {
        try await inner.storeBlockManifest(manifest, path: path, account: account)
    }

    // MARK: - Trash

    public func trash(path: CloudPath, account: CloudAccount) async throws {
        try await inner.trash(path: path, account: account)
    }

    public func listTrash(account: CloudAccount) async throws -> [CloudFileItem] {
        []
    }

    public func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {}
    public func emptyTrash(account: CloudAccount) async throws {}

    // MARK: - Versions

    public func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] {
        try await inner.listVersions(path: path, account: account)
    }

    public func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {
        try await inner.restoreVersion(version, account: account)
    }

    // MARK: - Sharing

    public func createShareLink(
        path: CloudPath,
        account: CloudAccount,
        options: ShareOptions
    ) async throws -> ShareLink {
        try await inner.createShareLink(path: path, account: account, options: options)
    }

    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {
        try await inner.revokeShareLink(link: link, account: account)
    }

    // MARK: - Streaming

    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await inner.streamingURL(path: path, account: account)
    }
}
