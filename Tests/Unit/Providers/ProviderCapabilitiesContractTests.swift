import XCTest
@testable import StratusCore

final class ProviderCapabilitiesContractTests: XCTestCase {
    func testDefaultCapabilitiesFavorMultipartResumeAndParallelChunks() {
        let capabilities = ProviderCapabilities()
        XCTAssertTrue(capabilities.supportsMultipartUpload)
        XCTAssertTrue(capabilities.supportsResumeUpload)
        XCTAssertTrue(capabilities.supportsParallelChunks)
        XCTAssertGreaterThanOrEqual(capabilities.maxConcurrentUploads, 1)
        XCTAssertGreaterThanOrEqual(capabilities.multipartThresholdBytes, 5 * 1024 * 1024)
    }

    func testSequentialProviderCanDisableParallelChunks() {
        let capabilities = ProviderCapabilities(supportsParallelChunks: false, maxConcurrentUploads: 1)
        XCTAssertFalse(capabilities.supportsParallelChunks)
        XCTAssertEqual(capabilities.maxConcurrentUploads, 1)
    }
}
