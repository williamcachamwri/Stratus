import XCTest
@testable import StratusCore

final class ConflictResolverTests: XCTestCase {
    private let resolver = ConflictResolver()

    private func makeConflict(
        localDate: Date,
        remoteDate: Date,
        localSize: Int64 = 100,
        remoteSize: Int64 = 200
    ) -> SyncConflict {
        SyncConflict(
            pairID: UUID(),
            localURL: URL(fileURLWithPath: "/tmp/test.txt"),
            remotePath: CloudPath("/remote/test.txt"),
            localModDate: localDate,
            remoteModDate: remoteDate,
            localSize: localSize,
            remoteSize: remoteSize
        )
    }

    func test_keepLocal_alwaysUploads() async throws {
        let conflict = makeConflict(localDate: Date.distantPast, remoteDate: Date())
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepLocal,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .upload = action { } else { XCTFail("Expected upload action") }
    }

    func test_keepRemote_alwaysDownloads() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date.distantPast)
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepRemote,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .download = action { } else { XCTFail("Expected download action") }
    }

    func test_keepNewer_localWins() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date.distantPast)
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepNewer,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .upload = action { } else { XCTFail("Expected upload for newer local") }
    }

    func test_keepNewer_remoteWins() async throws {
        let conflict = makeConflict(localDate: Date.distantPast, remoteDate: Date())
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepNewer,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .download = action { } else { XCTFail("Expected download for newer remote") }
    }

    func test_keepLarger_localLarger() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date(), localSize: 999, remoteSize: 100)
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepLarger,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .upload = action { } else { XCTFail("Expected upload for larger local") }
    }

    func test_keepBoth_producesBothActions() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date())
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepBoth,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .keepBoth = action { } else { XCTFail("Expected keepBoth action") }
    }

    func test_askUser_returnsNeedsDecision() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date())
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .askUser,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .needsUserDecision = action { } else { XCTFail("Expected needsUserDecision action") }
    }

    func test_keepNewer_equalModTime_prefersLocal() async throws {
        let now = Date()
        let conflict = makeConflict(localDate: now, remoteDate: now)
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepNewer,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .upload = action { } else { XCTFail("Equal mod times: keepNewer must prefer local (upload)") }
    }

    func test_keepLarger_equalSize_prefersLocal() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date(), localSize: 500, remoteSize: 500)
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepLarger,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case .upload = action { } else { XCTFail("Equal sizes: keepLarger must prefer local (upload)") }
    }

    func test_keepBoth_conflictCopyURL_containsConflict() async throws {
        let conflict = makeConflict(localDate: Date(), remoteDate: Date())
        let action = try await resolver.resolve(
            conflict: conflict,
            resolution: .keepBoth,
            provider: MockProvider(),
            account: makeAccount()
        )
        if case let .keepBoth(_, _, _, conflictURL) = action {
            XCTAssertTrue(
                conflictURL.lastPathComponent.contains("conflict"),
                "Conflict copy filename must contain 'conflict'"
            )
        } else {
            XCTFail("Expected keepBoth action")
        }
    }

    private func makeAccount() -> CloudAccount {
        CloudAccount(id: "test", providerID: "s3", displayName: "Test", email: nil)
    }
}

// MARK: - MockProvider for testing

private actor MockProvider: CloudProvider {
    nonisolated let id = "mock"
    nonisolated let displayName = "Mock"
    nonisolated let iconName = "mock"
    nonisolated let capabilities = ProviderCapabilities(
        supportsMultipartUpload: false,
        supportsResumeUpload: false,
        supportsParallelChunks: false,
        maxChunkSize: 1024,
        minChunkSize: 1,
        maxConcurrentUploads: 1,
        multipartThresholdBytes: .max
    )

    func authenticate(account: CloudAccount) async throws {}
    func refreshCredentials(account: CloudAccount) async throws {}
    func validateCredentials(account: CloudAccount) async throws -> Bool {
        true
    }

    func revokeCredentials(account: CloudAccount) async throws {}
    func quota(for account: CloudAccount) async throws -> StorageQuota {
        StorageQuota(
            totalBytes: nil,
            usedBytes: 0,
            availableBytes: nil
        )
    }

    func listDirectory(
        path: CloudPath,
        account: CloudAccount,
        pageToken: String?
    ) async throws -> PagedResult<[CloudFileItem]> {
        PagedResult(items: [])
    }

    func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: "",
            path: path
        )
    }

    func initiateMultipartUpload(
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> String {
        ""
    }

    func uploadChunk(
        uploadID: String,
        chunkNumber: Int,
        data: Data,
        account: CloudAccount
    ) async throws -> ChunkUploadResult {
        ChunkUploadResult(etag: nil)
    }

    func completeMultipartUpload(
        uploadID: String,
        parts: [CompletedPart],
        account: CloudAccount
    ) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: "",
            path: CloudPath("")
        )
    }

    func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}
    func uploadSmallFile(
        data: Data,
        remotePath: CloudPath,
        account: CloudAccount,
        metadata: UploadMetadata
    ) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: "",
            path: remotePath
        )
    }

    func downloadURL(
        path: CloudPath,
        account: CloudAccount,
        expiresIn: TimeInterval
    ) async throws -> URL {
        URL(string: "https://example.com")!
    }

    func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data {
        Data()
    }

    func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: "",
            path: path,
            isDirectory: true
        )
    }

    func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: "",
            path: to
        )
    }

    func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: "",
            path: to
        )
    }

    func delete(path: CloudPath, account: CloudAccount) async throws {}
    func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem {
        CloudFileItem(
            id: "",
            name: newName,
            path: path
        )
    }

    func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? {
        nil
    }

    nonisolated var supportsBlockManifest: Bool {
        false
    }

    func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? {
        nil
    }

    func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {}
    func trash(path: CloudPath, account: CloudAccount) async throws {}
    func listTrash(account: CloudAccount) async throws -> [CloudFileItem] {
        []
    }

    func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {}
    func emptyTrash(account: CloudAccount) async throws {}
    func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] {
        []
    }

    func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {}
    func createShareLink(
        path: CloudPath,
        account: CloudAccount,
        options: ShareOptions
    ) async throws -> ShareLink {
        ShareLink(
            url: URL(string: "https://example.com")!,
            id: ""
        )
    }

    func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL {
        URL(string: "https://example.com")!
    }
}
