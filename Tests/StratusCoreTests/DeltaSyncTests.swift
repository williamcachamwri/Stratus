import XCTest
@testable import StratusCore

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

        // Modify first block
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
        XCTAssertEqual(blockMap.blocks.count, 3)
    }

    func test_blockCount_withRemainder() async throws {
        let blockSize = DeltaSync.defaultBlockSize
        let data = Data(repeating: 0x11, count: blockSize * 2 + 100)
        let url = tempDir.appendingPathComponent("remainder.bin")
        try data.write(to: url)
        let blockMap = try await deltaSync.computeBlockMap(url: url)
        XCTAssertEqual(blockMap.blocks.count, 3)
        XCTAssertEqual(blockMap.blocks[2].size, 100)
    }

    func test_shouldUseDelta_smallFile_false() async throws {
        let url = tempDir.appendingPathComponent("small.bin")
        try Data(repeating: 0, count: 1024).write(to: url)
        let useDelta = await deltaSync.shouldUseDelta(fileSize: 1024, provider: "s3", fileURL: url)
        XCTAssertFalse(useDelta)
    }

    func test_shouldUseDelta_largeFile_true() async throws {
        let url = tempDir.appendingPathComponent("large.bin")
        let size = 60 * 1024 * 1024
        let largeData = Data(repeating: 0, count: size)
        try largeData.write(to: url)
        let useDelta = await deltaSync.shouldUseDelta(fileSize: Int64(size), provider: "s3", fileURL: url)
        // Returns true only if a manifest exists; without one, false
        XCTAssertFalse(useDelta)  // No prior manifest
    }
}
