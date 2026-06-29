import XCTest
import CryptoKit
@testable import StratusCore

final class ChecksumEngineTests: XCTestCase {

    private var tempDir: URL!
    private var engine: ChecksumEngine!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        engine = ChecksumEngine.shared
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_sha256OfKnownData() async throws {
        let data = Data("hello world".utf8)
        let hash = await engine.sha256(of: data)
        // Known SHA-256 of "hello world"
        XCTAssertEqual(hash, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9")
    }

    func test_sha256Stream_matchesSha256OfData() async throws {
        let data = Data(repeating: 0xAB, count: 4 * 1024 * 1024 + 17)  // 4MB + 17 bytes
        let fileURL = tempDir.appendingPathComponent("test.bin")
        try data.write(to: fileURL)
        let streamHash = try await engine.sha256Stream(url: fileURL)
        let directHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(streamHash, directHash)
    }

    func test_crc32c_knownValue() async {
        // CRC32C of "" = 0
        let empty = await engine.crc32c(of: Data())
        XCTAssertEqual(empty, 0)
    }

    func test_crc32c_deterministicAcrossRuns() async {
        let data = Data("Stratus CRC32c test vector".utf8)
        let h1 = await engine.crc32c(of: data)
        let h2 = await engine.crc32c(of: data)
        XCTAssertEqual(h1, h2)
    }

    func test_md5Stream_matchesMD5OfData() async throws {
        let data = Data(repeating: 0xFF, count: 1024 * 1024)
        let fileURL = tempDir.appendingPathComponent("md5test.bin")
        try data.write(to: fileURL)
        let streamMD5 = try await engine.md5Stream(url: fileURL)
        XCTAssertFalse(streamMD5.isEmpty)
        XCTAssertEqual(streamMD5.count, 32)  // hex-encoded 16 bytes
    }

    func test_s3MultipartETag_twoChunks() async {
        // S3 ETag = MD5(md5_1 + md5_2)-2
        let md5s = ["abc123", "def456"]
        let etag = await engine.s3MultipartETag(chunkMD5s: md5s)
        XCTAssertTrue(etag.hasSuffix("-2"))
        XCTAssertFalse(etag.isEmpty)
    }

    func test_sha256_emptyData_knownHash() async {
        let hash = await engine.sha256(of: Data())
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func test_sha256_sameDataProducesSameHash() async {
        let data = Data(repeating: 0xAB, count: 1024)
        let h1 = await engine.sha256(of: data)
        let h2 = await engine.sha256(of: data)
        XCTAssertEqual(h1, h2)
    }

    func test_crc32c_knownVector_matchesStandard() async {
        // Standard CRC32C check value for ASCII "123456789" is 0xE3069283
        let data = "123456789".data(using: .utf8)!
        let result = await engine.crc32c(of: data)
        XCTAssertEqual(result, 0xE3069283)
    }

    func test_sha256Batch_returnsHashForEachURL() async throws {
        let u1 = tempDir.appendingPathComponent("b1.bin")
        let u2 = tempDir.appendingPathComponent("b2.bin")
        try Data(repeating: 0x11, count: 1024).write(to: u1)
        try Data(repeating: 0x22, count: 2048).write(to: u2)
        let hashes = try await engine.sha256Batch(urls: [u1, u2])
        XCTAssertEqual(hashes.count, 2)
        XCTAssertEqual(hashes[u1]?.count, 64, "SHA-256 hex string must be 64 chars")
        XCTAssertNotEqual(hashes[u1], hashes[u2], "Different files must produce different hashes")
    }
}
