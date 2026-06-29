import XCTest
@testable import StratusCore

// Minimal mock provider for DeltaSync tests
actor MockCloudProvider: CloudProvider {
    nonisolated var id: String { "mock" }
    nonisolated var displayName: String { "Mock" }
    nonisolated var iconName: String { "mock" }
    nonisolated var capabilities: ProviderCapabilities { ProviderCapabilities() }
    nonisolated var supportsBlockManifest: Bool { false }

    func authenticate(account: CloudAccount) async throws {}
    func refreshCredentials(account: CloudAccount) async throws {}
    func validateCredentials(account: CloudAccount) async throws -> Bool { false }
    func revokeCredentials(account: CloudAccount) async throws {}
    func quota(for account: CloudAccount) async throws -> StorageQuota { StorageQuota(totalBytes: nil, usedBytes: 0, availableBytes: nil) }
    func listDirectory(path: CloudPath, account: CloudAccount, pageToken: String?) async throws -> PagedResult<[CloudFileItem]> { PagedResult(items: []) }
    func fileMetadata(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem { throw ProviderError.fileNotFound(path) }
    func initiateMultipartUpload(remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> String { "" }
    func uploadChunk(uploadID: String, chunkNumber: Int, data: Data, account: CloudAccount) async throws -> ChunkUploadResult { ChunkUploadResult(etag: nil) }
    func completeMultipartUpload(uploadID: String, parts: [CompletedPart], account: CloudAccount) async throws -> CloudFileItem { CloudFileItem(id: "", name: "", path: CloudPath("/")) }
    func abortMultipartUpload(uploadID: String, account: CloudAccount) async throws {}
    func uploadSmallFile(data: Data, remotePath: CloudPath, account: CloudAccount, metadata: UploadMetadata) async throws -> CloudFileItem { CloudFileItem(id: "", name: "", path: CloudPath("/")) }
    func downloadURL(path: CloudPath, account: CloudAccount, expiresIn: TimeInterval) async throws -> URL { throw ProviderError.unsupportedOperation("") }
    func downloadRange(path: CloudPath, range: ClosedRange<Int64>, account: CloudAccount) async throws -> Data { Data() }
    func createDirectory(path: CloudPath, account: CloudAccount) async throws -> CloudFileItem { CloudFileItem(id: "", name: "", path: path, isDirectory: true) }
    func move(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem { CloudFileItem(id: "", name: "", path: to) }
    func copy(from: CloudPath, to: CloudPath, account: CloudAccount) async throws -> CloudFileItem { CloudFileItem(id: "", name: "", path: to) }
    func delete(path: CloudPath, account: CloudAccount) async throws {}
    func rename(path: CloudPath, newName: String, account: CloudAccount) async throws -> CloudFileItem { CloudFileItem(id: "", name: newName, path: path) }
    func remoteChecksum(path: CloudPath, account: CloudAccount) async throws -> RemoteChecksum? { nil }
    func fetchBlockManifest(path: CloudPath, account: CloudAccount) async throws -> BlockMap? { nil }
    func storeBlockManifest(_ manifest: BlockMap, path: CloudPath, account: CloudAccount) async throws {}
    func trash(path: CloudPath, account: CloudAccount) async throws {}
    func listTrash(account: CloudAccount) async throws -> [CloudFileItem] { [] }
    func restoreFromTrash(item: CloudFileItem, account: CloudAccount) async throws {}
    func emptyTrash(account: CloudAccount) async throws {}
    func listVersions(path: CloudPath, account: CloudAccount) async throws -> [FileVersion] { [] }
    func restoreVersion(_ version: FileVersion, account: CloudAccount) async throws {}
    func createShareLink(path: CloudPath, account: CloudAccount, options: ShareOptions) async throws -> ShareLink { throw ProviderError.unsupportedOperation("") }
    func revokeShareLink(link: ShareLink, account: CloudAccount) async throws {}
    func streamingURL(path: CloudPath, account: CloudAccount) async throws -> URL { throw ProviderError.unsupportedOperation("") }
}

final class DeltaSyncTests: XCTestCase {

    private var tempDir: URL!
    private var deltaSync: DeltaSync!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        deltaSync = DeltaSync()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_identicalFiles_noChanges() async throws {
        let data = Data(repeating: 0x42, count: 512 * 1024)
        let url = tempDir.appendingPathComponent("same.bin")
        try data.write(to: url)
        let local = try await deltaSync.computeBlockMap(url: url)
        let diff = await deltaSync.diffBlockMaps(local: local, remote: local)
        XCTAssertTrue(diff.changedBlocks.isEmpty)
        XCTAssertTrue(diff.addedBlocks.isEmpty)
        XCTAssertTrue(diff.removedBlocks.isEmpty)
    }

    func test_singleBlockModified() async throws {
        var data = Data(repeating: 0x00, count: DeltaSync.defaultBlockSize * 4)
        let url = tempDir.appendingPathComponent("modified.bin")
        try data.write(to: url)
        let local = try await deltaSync.computeBlockMap(url: url)

        data[0] = 0xFF
        try data.write(to: url)
        let modified = try await deltaSync.computeBlockMap(url: url)

        let diff = await deltaSync.diffBlockMaps(local: local, remote: modified)
        XCTAssertFalse(diff.changedBlocks.isEmpty)
    }

    func test_blockCount_exactMultiple() async throws {
        let blockSize = DeltaSync.defaultBlockSize
        let data = Data(repeating: 0xAB, count: blockSize * 3)
        let url = tempDir.appendingPathComponent("exact.bin")
        try data.write(to: url)
        let blockMap = try await deltaSync.computeBlockMap(url: url)
        XCTAssertEqual(blockMap.checksums.count, 3)
    }

    func test_blockCount_withRemainder() async throws {
        let blockSize = DeltaSync.defaultBlockSize
        let data = Data(repeating: 0x11, count: blockSize * 2 + 100)
        let url = tempDir.appendingPathComponent("remainder.bin")
        try data.write(to: url)
        let blockMap = try await deltaSync.computeBlockMap(url: url)
        XCTAssertEqual(blockMap.checksums.count, 3)
        XCTAssertEqual(blockMap.fileSize, Int64(blockSize * 2 + 100))
    }

    func test_shouldUseDelta_smallFile_false() async throws {
        let url = tempDir.appendingPathComponent("small.bin")
        try Data(repeating: 0, count: 1024).write(to: url)
        let provider = MockCloudProvider()
        let useDelta = await deltaSync.shouldUseDelta(fileSize: 1024, provider: provider, fileURL: url)
        XCTAssertFalse(useDelta)
    }

    func test_shouldUseDelta_largeFile_noManifest_false() async throws {
        let url = tempDir.appendingPathComponent("large.bin")
        let size = 60 * 1024 * 1024
        try Data(repeating: 0, count: size).write(to: url)
        let provider = MockCloudProvider()
        let useDelta = await deltaSync.shouldUseDelta(fileSize: Int64(size), provider: provider, fileURL: url)
        XCTAssertFalse(useDelta)  // False: provider doesn't support block manifest
    }

    func test_allBlocksChanged_allBlocksReturned() async throws {
        let blockSize = DeltaSync.defaultBlockSize
        let url1 = tempDir.appendingPathComponent("all_a.bin")
        let url2 = tempDir.appendingPathComponent("all_b.bin")
        try Data(repeating: 0x00, count: blockSize * 3).write(to: url1)
        try Data(repeating: 0xFF, count: blockSize * 3).write(to: url2)
        let map1 = try await deltaSync.computeBlockMap(url: url1)
        let map2 = try await deltaSync.computeBlockMap(url: url2)
        let diff = await deltaSync.diffBlockMaps(local: map1, remote: map2)
        XCTAssertEqual(diff.changedBlocks.count, 3, "All 3 blocks differ → all 3 must appear in changedBlocks")
    }

    func test_emptyFile_zeroBlocks() async throws {
        let url = tempDir.appendingPathComponent("empty_delta.bin")
        try Data().write(to: url)
        let blockMap = try await deltaSync.computeBlockMap(url: url)
        XCTAssertEqual(blockMap.checksums.count, 0)
        XCTAssertEqual(blockMap.fileSize, 0)
    }

    func test_blockChecksums_deterministicForSameData() async throws {
        let data = Data(repeating: 0x42, count: DeltaSync.defaultBlockSize * 2)
        let url = tempDir.appendingPathComponent("determ.bin")
        try data.write(to: url)
        let map1 = try await deltaSync.computeBlockMap(url: url)
        let map2 = try await deltaSync.computeBlockMap(url: url)
        XCTAssertEqual(map1.checksums, map2.checksums)
        XCTAssertEqual(map1.sha256, map2.sha256)
    }

    func test_diff_addedBlocks_whenLocalHasMoreBlocks() async throws {
        let blockSize = DeltaSync.defaultBlockSize
        let smallURL = tempDir.appendingPathComponent("diff_small.bin")
        let largeURL = tempDir.appendingPathComponent("diff_large.bin")
        try Data(repeating: 0x11, count: blockSize).write(to: smallURL)
        try Data(repeating: 0x11, count: blockSize * 3).write(to: largeURL)
        let smallMap = try await deltaSync.computeBlockMap(url: smallURL)
        let largeMap = try await deltaSync.computeBlockMap(url: largeURL)
        let diff = await deltaSync.diffBlockMaps(local: largeMap, remote: smallMap)
        XCTAssertEqual(diff.addedBlocks.count, 2, "Local has 3 blocks, remote has 1 → 2 added blocks")
    }
}
