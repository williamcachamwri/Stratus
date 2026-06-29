import XCTest
@testable import StratusCore

final class GoogleDriveProviderTests: XCTestCase {

    private let provider = GoogleDriveProvider()

    func test_provider_id() {
        XCTAssertEqual(provider.id, "gdrive")
    }

    func test_provider_display_name() {
        XCTAssertEqual(provider.displayName, "Google Drive")
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    func test_capabilities_multipart_supported() {
        XCTAssertTrue(provider.capabilities.supportsMultipartUpload)
    }

    func test_capabilities_resume_supported() {
        XCTAssertTrue(provider.capabilities.supportsResumeUpload)
    }

    func test_capabilities_chunk_sizes_valid() {
        XCTAssertGreaterThan(provider.capabilities.maxChunkSize, 0)
        XCTAssertGreaterThanOrEqual(provider.capabilities.maxChunkSize, provider.capabilities.minChunkSize)
    }

    func test_capabilities_concurrent_uploads_positive() {
        XCTAssertGreaterThan(provider.capabilities.maxConcurrentUploads, 0)
    }

    func test_block_manifest_supported() {
        XCTAssertTrue(provider.supportsBlockManifest)
    }

    func test_capabilities_sendable() {
        func check<T: Sendable>(_: T) {}
        check(provider.capabilities)
    }

    func test_cloud_path_root_is_slash() {
        XCTAssertEqual(CloudPath("/").path, "/")
    }

    func test_cloud_path_append_and_last_component() {
        let base = CloudPath("/My Drive")
        let child = base.appendingComponent("Notes.txt")
        XCTAssertEqual(child.lastComponent, "Notes.txt")
    }

    func test_provider_capabilities_multipart_threshold() {
        XCTAssertGreaterThan(provider.capabilities.multipartThresholdBytes, 0)
    }
}
