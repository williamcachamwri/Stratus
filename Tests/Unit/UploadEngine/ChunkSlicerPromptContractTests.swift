import XCTest
@testable import StratusCore

final class ChunkSlicerPromptContractTests: XCTestCase {
    func testSmallFileUsesSingleChunk() {
        let chunks = ChunkSlicer.slice(fileSize: 4 * 1024 * 1024, chunkSize: 8 * 1024 * 1024)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.offset, 0)
        XCTAssertEqual(chunks.first?.size, 4 * 1024 * 1024)
        XCTAssertTrue(chunks.first?.isLast == true)
    }

    func testChunkOffsetsAreContiguousForLargeFile() {
        let chunkSize = 16 * 1024 * 1024
        let chunks = ChunkSlicer.slice(fileSize: Int64(chunkSize * 3 + 4096), chunkSize: chunkSize)
        XCTAssertEqual(chunks.map(\.number), Array(0..<chunks.count))
        for pair in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(pair.1.offset, pair.0.offset + Int64(pair.0.size))
        }
        XCTAssertEqual(chunks.last?.size, 4096)
    }
}
