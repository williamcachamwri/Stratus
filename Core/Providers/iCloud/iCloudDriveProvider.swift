import Foundation
import os.log

// MARK: - iCloudDriveProvider
// Bridges NSFileManager's ubiquitous container APIs into the CloudProvider interface.
// Uses NSMetadataQuery to enumerate iCloud files and triggers download on demand.

public actor iCloudDriveProvider: CloudProvider {
    public nonisolated let id = "icloud"
    public nonisolated let displayName = "iCloud Drive"
    public nonisolated let iconName = "icloud"
    public nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: false,
        supportsParallelChunks: false,
        maxChunkSize: 256 * 1024 * 1024,
        minChunkSize: 1,
        maxConcurrentUploads: 4,
        multipartThresholdBytes: Int.max
    )

    private let containerID = "iCloud.com.stratus.cloudmanager"
    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "iCloudDriveProvider")

    // Container root URL resolved lazily
    private var containerURL: URL? {
        fileManager.url(forUbiquityContainerIdentifier: containerID)?.appendingPathComponent("Documents")
    }

    public init() {}

    // MARK: - Auth (iCloud auth is handled by OS)

    public func authenticate(account: CloudAccount) async throws {
        guard containerURL != nil else {
            throw ProviderError.authenticationFailed("iCloud Drive container unavailable — user may not be signed in")
        }
    }
    public func refreshCredentials(account: CloudAccount) async throws {}
    public func validateCredentials(account: CloudAccount) async throws -> Bool { containerURL != nil }
    public func revokeCredentials(account: CloudAccount) async throws {}

    // MARK: - Quota

    public func quota(for account: CloudAccount) async throws -> StorageQuota {
        // iCloud quota not accessible via public API; return unknown
        StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil)
    }

    // MARK: - Directory Listing

    public func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container not available") }
        let dir = path.path == "/" ? base : base.appendingPathComponent(path.path)
        let entries = try fileManager.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemIsDownloadingKey],
            options: [.skipsHiddenFiles])
        let items = try entries.map { url -> CloudFileItem in
            let rv = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = rv.isDirectory ?? false
            let size = rv.fileSize.map(Int64.init) ?? 0
            let mod = rv.contentModificationDate
            let relative = url.path.replacingOccurrences(of: base.path + "/", with: "")
            return CloudFileItem(
                id: relative,
                name: url.lastPathComponent,
                path: CloudPath(relative),
                size: isDir ? nil : size,
                modificationDate: mod,
                isDirectory: isDir
            )
        }
        return PagedResult(items: items)
    }

    public func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let url = base.appendingPathComponent(path.path)
        let rv = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return CloudFileItem(
            id: path.path,
            name: url.lastPathComponent,
            path: path,
            size: (rv.fileSize).map(Int64.init),
            modificationDate: rv.contentModificationDate,
            isDirectory: rv.isDirectory ?? false
        )
    }

    // MARK: - Upload

    public func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String { remotePath.path }
    public func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult { ChunkUploadResult(etag: nil) }
    public func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(id: uploadID, name: (uploadID as NSString).lastPathComponent, path: CloudPath(uploadID))
    }
    public func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}

    public func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let dest = base.appendingPathComponent(remotePath.path)
        try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: dest, options: .atomic)
        // Trigger iCloud upload
        try fileManager.setUbiquitous(true, itemAt: dest, destinationURL: dest)
        logger.debug("Uploaded to iCloud: \(remotePath.path)")
        return CloudFileItem(id: remotePath.path, name: remotePath.lastComponent, path: remotePath, size: Int64(data.count))
    }

    // MARK: - Download

    public func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let url = base.appendingPathComponent(path.path)
        // Trigger download if the file is in the cloud
        try fileManager.startDownloadingUbiquitousItem(at: url)
        return url
    }

    public func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        let url = try await downloadURL(path: path, account: account, expiresIn: 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        let length = Int(range.upperBound - range.lowerBound + 1)
        return (try? handle.read(upToCount: length)) ?? Data()
    }

    // MARK: - File Operations

    public func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let dir = base.appendingPathComponent(path.path)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return CloudFileItem(id: path.path, name: path.lastComponent, path: path, isDirectory: true)
    }

    public func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let src = base.appendingPathComponent(from.path)
        let dst = base.appendingPathComponent(to.path)
        try fileManager.moveItem(at: src, to: dst)
        return CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let src = base.appendingPathComponent(from.path)
        let dst = base.appendingPathComponent(to.path)
        try fileManager.copyItem(at: src, to: dst)
        return CloudFileItem(id: to.path, name: to.lastComponent, path: to)
    }

    public func delete(path: CloudPath, account: CloudAccount) async throws {
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let url = base.appendingPathComponent(path.path)
        try fileManager.removeItem(at: url)
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
        guard let base = containerURL else { throw ProviderError.authenticationFailed("iCloud container unavailable") }
        let url = base.appendingPathComponent(path.path)
        return ShareLink(url: url, id: path.path)
    }
    public func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    public func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        try await downloadURL(path: path, account: account, expiresIn: 0)
    }
}
