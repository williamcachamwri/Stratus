import Foundation

// MARK: - Core Types

public struct CloudPath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let path: String

    public init(_ path: String) {
        self.path = path.hasPrefix("/") ? path : "/" + path
    }

    public var description: String { path }
    public var lastComponent: String { (path as NSString).lastPathComponent }
    public var deletingLastComponent: CloudPath { CloudPath((path as NSString).deletingLastPathComponent) }

    public func appendingComponent(_ name: String) -> CloudPath {
        CloudPath(path + "/" + name)
    }
}

public struct CloudFileItem: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let path: CloudPath
    public let size: Int64?
    public let contentType: String?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let isDirectory: Bool
    public let etag: String?
    public let versionID: String?
    public let isShared: Bool
    public let downloadURL: URL?

    public init(
        id: String,
        name: String,
        path: CloudPath,
        size: Int64? = nil,
        contentType: String? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        isDirectory: Bool = false,
        etag: String? = nil,
        versionID: String? = nil,
        isShared: Bool = false,
        downloadURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.contentType = contentType
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isDirectory = isDirectory
        self.etag = etag
        self.versionID = versionID
        self.isShared = isShared
        self.downloadURL = downloadURL
    }
}

public struct PagedResult<T: Sendable>: Sendable {
    public let items: T
    public let nextPageToken: String?
    public let totalCount: Int?

    public init(items: T, nextPageToken: String? = nil, totalCount: Int? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken
        self.totalCount = totalCount
    }
}

public struct StorageQuota: Sendable {
    public let totalBytes: Int64?
    public let usedBytes: Int64
    public let availableBytes: Int64?

    public init(totalBytes: Int64?, usedBytes: Int64, availableBytes: Int64?) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }

    public var usagePercent: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return Double(usedBytes) / Double(total)
    }
}

public struct CloudAccount: Sendable, Identifiable, Codable, Hashable {
    public let id: String
    public let providerID: String
    public let displayName: String
    public let email: String?
    public let createdAt: Date

    public init(id: String, providerID: String, displayName: String, email: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName
        self.email = email
        self.createdAt = createdAt
    }
}

public struct UploadMetadata: Sendable {
    public let contentType: String?
    public let modificationDate: Date?
    public let customAttributes: [String: String]

    public init(contentType: String? = nil, modificationDate: Date? = nil, customAttributes: [String: String] = [:]) {
        self.contentType = contentType
        self.modificationDate = modificationDate
        self.customAttributes = customAttributes
    }
}

public struct ChunkUploadResult: Sendable {
    public let etag: String?
    public let checksum: String?
    public let serverConfirmedChecksum: Bool

    public init(etag: String?, checksum: String? = nil, serverConfirmedChecksum: Bool = false) {
        self.etag = etag
        self.checksum = checksum
        self.serverConfirmedChecksum = serverConfirmedChecksum
    }
}

public struct CompletedPart: Sendable, Codable {
    public let partNumber: Int
    public let etag: String

    public init(partNumber: Int, etag: String) {
        self.partNumber = partNumber
        self.etag = etag
    }
}

public struct RemoteChecksum: Sendable {
    public enum Algorithm: String, Sendable { case md5, sha256, sha1, crc32c }
    public let algorithm: Algorithm
    public let value: String

    public init(algorithm: Algorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

public struct BlockMap: Codable, Sendable {
    public let fileSize: Int64
    public let blockSize: Int
    public let checksums: [String]
    public let sha256: String
    public let modificationDate: Date

    public init(fileSize: Int64, blockSize: Int, checksums: [String], sha256: String, modificationDate: Date) {
        self.fileSize = fileSize
        self.blockSize = blockSize
        self.checksums = checksums
        self.sha256 = sha256
        self.modificationDate = modificationDate
    }
}

public struct FileVersion: Sendable, Identifiable {
    public let id: String
    public let versionID: String
    public let size: Int64
    public let modificationDate: Date
    public let isLatest: Bool

    public init(id: String, versionID: String, size: Int64, modificationDate: Date, isLatest: Bool) {
        self.id = id
        self.versionID = versionID
        self.size = size
        self.modificationDate = modificationDate
        self.isLatest = isLatest
    }
}

public struct ShareOptions: Sendable {
    public let expiresAt: Date?
    public let password: String?
    public let canEdit: Bool
    public let canComment: Bool

    public init(expiresAt: Date? = nil, password: String? = nil, canEdit: Bool = false, canComment: Bool = false) {
        self.expiresAt = expiresAt
        self.password = password
        self.canEdit = canEdit
        self.canComment = canComment
    }
}

public struct ShareLink: Sendable {
    public let url: URL
    public let expiresAt: Date?
    public let id: String

    public init(url: URL, expiresAt: Date? = nil, id: String) {
        self.url = url
        self.expiresAt = expiresAt
        self.id = id
    }
}

// MARK: - Provider Capabilities

public struct ProviderRateLimits: Sendable {
    public let requestsPerSecond: Double?
    public let uploadBandwidthBPS: Double?
    public let downloadBandwidthBPS: Double?
    public let apiCallsPerDay: Int?

    public init(
        requestsPerSecond: Double? = nil,
        uploadBandwidthBPS: Double? = nil,
        downloadBandwidthBPS: Double? = nil,
        apiCallsPerDay: Int? = nil
    ) {
        self.requestsPerSecond = requestsPerSecond
        self.uploadBandwidthBPS = uploadBandwidthBPS
        self.downloadBandwidthBPS = downloadBandwidthBPS
        self.apiCallsPerDay = apiCallsPerDay
    }
}

public struct ProviderCapabilities: Sendable {
    public let supportsMultipartUpload: Bool
    public let supportsResumeUpload: Bool
    public let supportsParallelChunks: Bool
    public let maxChunkSize: Int
    public let minChunkSize: Int
    public let maxConcurrentUploads: Int
    public let supportsTransferAcceleration: Bool
    public let supportsVersioning: Bool
    public let supportsTrash: Bool
    public let supportsBlockManifest: Bool
    public let supportsDeltaSync: Bool
    public let supportsCRC32c: Bool
    public let supportsSHA256ETag: Bool
    public let supportsServerSideCopy: Bool
    public let maxFileSizeBytes: Int64?
    public let multipartThresholdBytes: Int
    public let rateLimits: ProviderRateLimits

    public init(
        supportsMultipartUpload: Bool = true,
        supportsResumeUpload: Bool = true,
        supportsParallelChunks: Bool = true,
        maxChunkSize: Int = 5 * 1024 * 1024 * 1024,
        minChunkSize: Int = 5 * 1024 * 1024,
        maxConcurrentUploads: Int = 32,
        supportsTransferAcceleration: Bool = false,
        supportsVersioning: Bool = false,
        supportsTrash: Bool = false,
        supportsBlockManifest: Bool = false,
        supportsDeltaSync: Bool = false,
        supportsCRC32c: Bool = false,
        supportsSHA256ETag: Bool = true,
        supportsServerSideCopy: Bool = false,
        maxFileSizeBytes: Int64? = nil,
        multipartThresholdBytes: Int = 5 * 1024 * 1024,
        rateLimits: ProviderRateLimits = ProviderRateLimits()
    ) {
        self.supportsMultipartUpload = supportsMultipartUpload
        self.supportsResumeUpload = supportsResumeUpload
        self.supportsParallelChunks = supportsParallelChunks
        self.maxChunkSize = maxChunkSize
        self.minChunkSize = minChunkSize
        self.maxConcurrentUploads = maxConcurrentUploads
        self.supportsTransferAcceleration = supportsTransferAcceleration
        self.supportsVersioning = supportsVersioning
        self.supportsTrash = supportsTrash
        self.supportsBlockManifest = supportsBlockManifest
        self.supportsDeltaSync = supportsDeltaSync
        self.supportsCRC32c = supportsCRC32c
        self.supportsSHA256ETag = supportsSHA256ETag
        self.supportsServerSideCopy = supportsServerSideCopy
        self.maxFileSizeBytes = maxFileSizeBytes
        self.multipartThresholdBytes = multipartThresholdBytes
        self.rateLimits = rateLimits
    }
}

// MARK: - Errors

public enum ProviderError: Error, Sendable {
    case accessDenied(String)
    case fileNotFound(CloudPath)
    case sessionExpired
    case quotaExceeded
    case networkUnavailable
    case rateLimited(retryAfter: TimeInterval)
    case serverError(statusCode: Int, message: String)
    case checksumMismatch(expected: String, actual: String)
    case unsupportedOperation(String)
    case authenticationFailed(String)
    case invalidResponse(String)
    case providerSpecific(code: String, message: String)
}

// MARK: - CloudProvider Protocol

public protocol CloudProvider: Actor, Sendable {

    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var iconName: String { get }
    nonisolated var capabilities: ProviderCapabilities { get }

    // Authentication
    func authenticate(account: CloudAccount) async throws
    func refreshCredentials(account: CloudAccount) async throws
    func validateCredentials(account: CloudAccount) async throws -> Bool
    func revokeCredentials(account: CloudAccount) async throws

    // Quota
    func quota(for account: CloudAccount) async throws -> StorageQuota

    // File listing
    func listDirectory(
        path: CloudPath,
        account: CloudAccount,
        pageToken: String?
    ) async throws -> PagedResult<[CloudFileItem]>

    func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem

    // Multipart upload
    func initiateMultipartUpload(
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> String

    func uploadChunk(
        uploadID: String,
        chunkNumber: Int,
        data: Data,
        account: CloudAccount
    ) async throws -> ChunkUploadResult

    func completeMultipartUpload(
        uploadID: String,
        parts: [CompletedPart],
        account: CloudAccount
    ) async throws -> CloudFileItem

    func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws

    // Small file upload
    func uploadSmallFile(
        data: Data,
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> CloudFileItem

    // Download
    func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL
    func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data

    // File operations
    func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem
    func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem
    func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem
    func delete(path: CloudPath, account: CloudAccount) async throws
    func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem

    // Checksums
    func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum?

    // Delta sync
    nonisolated var supportsBlockManifest: Bool { get }
    func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap?
    func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws

    // Trash
    func trash(path: CloudPath, account: CloudAccount) async throws
    func listTrash(account: CloudAccount) async throws -> [CloudFileItem]
    func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws
    func emptyTrash(account: CloudAccount) async throws

    // Version history
    func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion]
    func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws

    // Sharing
    func createShareLink(path: CloudPath, account: CloudAccount, options: ShareOptions) async throws -> ShareLink
    func revokeShareLink(link: ShareLink, account: CloudAccount) async throws

    // Streaming
    func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL
}

// MARK: - CloudProviderRegistry

public actor CloudProviderRegistry {
    public static let shared = CloudProviderRegistry()

    private var providers: [String: any CloudProvider] = [:]

    private init() {}

    public func register(_ provider: some CloudProvider) {
        providers[provider.id] = provider
    }

    public func provider(id: String) -> (any CloudProvider)? {
        providers[id]
    }

    public var allProviders: [any CloudProvider] {
        Array(providers.values)
    }
}
