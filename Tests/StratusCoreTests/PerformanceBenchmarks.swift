import XCTest
import CryptoKit
@testable import StratusCore

final class PerformanceBenchmarks: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - ChunkSlicer Performance

    func test_chunkSlicer_1GBFile_under1ms() {
        let fileSize = Int64(1024 * 1024 * 1024)
        measure {
            _ = ChunkSlicer.slice(fileSize: fileSize, chunkSize: 5 * 1024 * 1024)
        }
    }

    // MARK: - CRC32c Performance

    func test_crc32c_1MB_under5ms() async {
        let data = Data(repeating: 0xAB, count: 1024 * 1024)
        let engine = ChecksumEngine.shared
        measure {
            let exp = expectation(description: "crc32c")
            Task {
                _ = await engine.crc32c(of: data)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 5.0)
        }
    }

    // MARK: - SHA-256 Performance

    func test_sha256_4MB_file() async throws {
        let data = Data(repeating: 0xFF, count: 4 * 1024 * 1024)
        let url = tempDir.appendingPathComponent("sha256bench.bin")
        try data.write(to: url)
        let engine = ChecksumEngine.shared
        measure {
            let exp = expectation(description: "sha256")
            Task {
                _ = try? await engine.sha256Stream(url: url)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 10.0)
        }
    }

    // MARK: - Encryption Performance

    func test_encryption_1MB_roundTrip() async throws {
        let key = SymmetricKey(size: .bits256)
        let enc = ClientSideEncryption(masterKey: key)
        let data = Data(repeating: 0xAA, count: 1024 * 1024)
        let plainURL = tempDir.appendingPathComponent("perf_plain.bin")
        let encURL = tempDir.appendingPathComponent("perf_enc.stre")
        let decURL = tempDir.appendingPathComponent("perf_dec.bin")
        try data.write(to: plainURL)
        measure {
            let exp = expectation(description: "enc_dec")
            Task {
                try? await enc.encrypt(fileURL: plainURL, to: encURL)
                try? await enc.decrypt(encryptedURL: encURL, to: decURL)
                exp.fulfill()
            }
            wait(for: [exp], timeout: 15.0)
        }
    }

    // MARK: - BandwidthMonitor EWMA Performance

    func test_bandwidthMonitor_10kSamples() async {
        let monitor = BandwidthMonitor()
        measure {
            let exp = expectation(description: "bw_samples")
            Task {
                for _ in 0..<10_000 {
                    await monitor.recordBytes(1_000_000, elapsed: 1.0)
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: 30.0)
        }
    }
}
