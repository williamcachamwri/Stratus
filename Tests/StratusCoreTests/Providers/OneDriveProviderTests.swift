import XCTest
@testable import StratusCore

final class OneDriveProviderTests: XCTestCase {
    private let provider = OneDriveProvider()

    func test_provider_id() {
        XCTAssertEqual(provider.id, "onedrive")
    }

    func test_provider_display_name() {
        XCTAssertFalse(provider.displayName.isEmpty)
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    func test_capabilities_multipart_supported() {
        XCTAssertFalse(provider.capabilities.supportsMultipartUpload)
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

    func test_capabilities_multipart_threshold_positive() {
        XCTAssertGreaterThan(provider.capabilities.multipartThresholdBytes, 0)
    }

    func test_capabilities_sendable() {
        func check(_: some Sendable) {}
        check(provider.capabilities)
    }

    func test_cloud_path_append_file() {
        let path = CloudPath("/Documents").appendingComponent("report.docx")
        XCTAssertTrue(path.path.hasSuffix("report.docx"))
    }

    func test_cloud_path_root_last_component() {
        let path = CloudPath("/")
        // Root component is either empty string or "/" — should not crash
        _ = path.lastComponent
    }
}
