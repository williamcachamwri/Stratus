import XCTest
@testable import StratusCore

final class ChunkSlicerTests: XCTestCase {

    func test_sliceSingleChunk_smallFile() {
        let chunks = ChunkSlicer.slice(fileSize: 100, chunkSize: 5 * 1024 * 1024)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].offset, 0)
        XCTAssertEqual(chunks[0].size, 100)
        XCTAssertTrue(chunks[0].isLast)
    }

    func test_sliceExactMultiple() {
        let chunkSize = 5 * 1024 * 1024
        let fileSize = chunkSize * 4
        let chunks = ChunkSlicer.slice(fileSize: Int64(fileSize), chunkSize: chunkSize)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertFalse(chunks[0].isLast)
        XCTAssertFalse(chunks[1].isLast)
        XCTAssertFalse(chunks[2].isLast)
        XCTAssertTrue(chunks[3].isLast)
        XCTAssertEqual(chunks[3].number, 3)
    }

    func test_sliceRemainder() {
        let chunkSize = 5 * 1024 * 1024
        let fileSize = Int64(chunkSize * 3 + 100)
        let chunks = ChunkSlicer.slice(fileSize: fileSize, chunkSize: chunkSize)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[3].size, 100)
        XCTAssertTrue(chunks[3].isLast)
    }

    func test_chunkOffsets_noOverlap() {
        let chunkSize = 8 * 1024 * 1024
        let fileSize = Int64(chunkSize * 5 + 1234)
        let chunks = ChunkSlicer.slice(fileSize: fileSize, chunkSize: chunkSize)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].offset, chunks[i-1].offset + Int64(chunks[i-1].size))
        }
        let totalCovered = chunks.reduce(Int64(0)) { $0 + Int64($1.size) }
        XCTAssertEqual(totalCovered, fileSize)
    }

    func test_defaultChunkSize_smallFile() {
        // Files under 5 MB are treated as single-part; chunk size = file size
        XCTAssertEqual(ChunkSlicer.defaultChunkSize(for: 1 * 1024 * 1024), 1 * 1024 * 1024)
    }

    func test_defaultChunkSize_largeFile() {
        let size = Int64(2 * 1024 * 1024 * 1024)  // 2 GB
        let chunk = ChunkSlicer.defaultChunkSize(for: size)
        // Should produce at most ~1000 parts per S3 limits
        let numParts = Int(ceil(Double(size) / Double(chunk)))
        XCTAssertLessThanOrEqual(numParts, 1000)
    }

    func test_zeroFileSize() {
        let chunks = ChunkSlicer.slice(fileSize: 0, chunkSize: 5 * 1024 * 1024)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].size, 0)
    }

    func test_firstChunk_numberIsZero() {
        let chunks = ChunkSlicer.slice(fileSize: 100, chunkSize: 5 * 1024 * 1024)
        XCTAssertEqual(chunks[0].number, 0)
    }

    func test_allChunks_sequentialNumbers() {
        let chunkSize = 5 * 1024 * 1024
        let chunks = ChunkSlicer.slice(fileSize: Int64(chunkSize * 5), chunkSize: chunkSize)
        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.number, i, "Chunk numbers must be sequential starting at 0")
        }
    }

    func test_onlyLastChunk_isLast() {
        let chunkSize = 5 * 1024 * 1024
        let chunks = ChunkSlicer.slice(fileSize: Int64(chunkSize * 3 + 100), chunkSize: chunkSize)
        XCTAssertEqual(chunks.count, 4)
        for i in 0..<3 {
            XCTAssertFalse(chunks[i].isLast, "Chunk \(i) must not be marked last")
        }
        XCTAssertTrue(chunks[3].isLast, "Only the final chunk must be marked last")
    }

    func test_defaultChunkSize_100MB_file() {
        let size = Int64(100 * 1024 * 1024)
        let chunkSize = ChunkSlicer.defaultChunkSize(for: size)
        // 100 MB boundary: uses 16 MB chunks
        XCTAssertEqual(chunkSize, 16 * 1024 * 1024)
    }
    func test_readChunk_returnsExactRequestedBytes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data((0..<4096).map { UInt8($0 % 251) })
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let chunk = try ChunkSlicer.readChunk(fileHandle: handle, offset: 512, size: 1024)
        XCTAssertEqual(chunk.count, 1024)
        XCTAssertEqual(chunk, data[512..<1536])
    }

    func test_readChunk_throwsOnShortRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1, 2, 3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        XCTAssertThrowsError(try ChunkSlicer.readChunk(fileHandle: handle, offset: 0, size: 8)) { error in
            XCTAssertEqual(error as? ChunkSlicerError, .shortRead(expected: 8, actual: 4))
        }
    }

}
