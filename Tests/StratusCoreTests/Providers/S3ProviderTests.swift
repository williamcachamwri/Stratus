import XCTest
@testable import StratusCore

final class S3ProviderTests: XCTestCase {
    private let provider = S3Provider(config: S3Configuration(bucket: "stratus-unit-tests"))

    // MARK: - Identity

    func test_provider_id() {
        XCTAssertEqual(provider.id, "s3")
    }

    func test_provider_display_name() {
        XCTAssertFalse(provider.displayName.isEmpty)
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    // MARK: - Capabilities

    func test_capabilities_multipart_supported() {
        XCTAssertTrue(provider.capabilities.supportsMultipartUpload)
    }

    func test_capabilities_chunk_sizes_valid() {
        XCTAssertGreaterThan(provider.capabilities.maxChunkSize, 0)
        XCTAssertGreaterThan(provider.capabilities.minChunkSize, 0)
        XCTAssertGreaterThanOrEqual(provider.capabilities.maxChunkSize, provider.capabilities.minChunkSize)
    }

    func test_capabilities_concurrent_uploads_positive() {
        XCTAssertGreaterThan(provider.capabilities.maxConcurrentUploads, 0)
    }

    func test_capabilities_multipart_threshold_positive() {
        XCTAssertGreaterThan(provider.capabilities.multipartThresholdBytes, 0)
    }

    // MARK: - CloudPath basics

    func test_cloud_path_root() {
        let path = CloudPath("/")
        XCTAssertEqual(path.path, "/")
    }

    func test_cloud_path_last_component() {
        let path = CloudPath("/bucket/folder/file.txt")
        XCTAssertEqual(path.lastComponent, "file.txt")
    }

    func test_cloud_path_deleting_last_component() {
        let path = CloudPath("/bucket/folder/file.txt")
        let parent = path.deletingLastComponent
        XCTAssertEqual(parent.path, "/bucket/folder")
    }

    func test_cloud_path_appending_component() {
        let base = CloudPath("/bucket/folder")
        let child = base.appendingComponent("file.txt")
        XCTAssertTrue(child.path.hasSuffix("file.txt"))
    }

    // MARK: - ProviderCapabilities Sendable

    func test_capabilities_sendable() {
        func check(_: some Sendable) {}
        check(provider.capabilities)
    }

    // MARK: - Block manifest

    func test_block_manifest_supported() {
        XCTAssertTrue(provider.supportsBlockManifest)
    }
}
