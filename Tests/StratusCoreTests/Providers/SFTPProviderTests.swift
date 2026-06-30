import XCTest
@testable import StratusCore

final class SFTPProviderTests: XCTestCase {
    private let provider = SFTPProvider()

    func test_provider_id() {
        XCTAssertEqual(provider.id, "sftp")
    }

    func test_provider_display_name() {
        XCTAssertFalse(provider.displayName.isEmpty)
    }

    func test_provider_icon_name() {
        XCTAssertFalse(provider.iconName.isEmpty)
    }

    func test_capabilities_concurrent_uploads_positive() {
        XCTAssertGreaterThan(provider.capabilities.maxConcurrentUploads, 0)
    }

    func test_capabilities_chunk_sizes_valid() {
        XCTAssertGreaterThan(provider.capabilities.maxChunkSize, 0)
        XCTAssertGreaterThanOrEqual(provider.capabilities.maxChunkSize, provider.capabilities.minChunkSize)
    }

    func test_capabilities_sendable() {
        func check(_: some Sendable) {}
        check(provider.capabilities)
    }

    func test_validate_credentials_throws_without_account() async {
        let account = CloudAccount(id: "sftp-no-host", providerID: "sftp", displayName: "Test SFTP", email: nil)
        // Without real credentials this must throw, not hang or crash
        let valid = try? await provider.validateCredentials(account: account)
        // Either throws or returns false — never silently succeeds
        if let v = valid { XCTAssertFalse(v) }
    }

    func test_cloud_path_unix_style() {
        let path = CloudPath("/home/user/files/doc.txt")
        XCTAssertEqual(path.lastComponent, "doc.txt")
        XCTAssertEqual(path.deletingLastComponent.path, "/home/user/files")
    }
}
