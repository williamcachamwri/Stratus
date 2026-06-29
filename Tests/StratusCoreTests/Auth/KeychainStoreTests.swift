import XCTest
@testable import StratusCore

final class KeychainStoreTests: XCTestCase {

    private let store = KeychainStore.shared
    private let testService = "com.stratus.test.keychain"
    private let testAccount = "unit-test-\(UUID().uuidString)"

    override func tearDown() async throws {
        // Clean up any leftover test items
        try? await store.deleteToken(service: testService, account: testAccount)
        try? await store.deleteSecret(service: testService, account: testAccount)
        try await super.tearDown()
    }

    // MARK: - Token (Internet Password)

    func test_save_and_load_token() async throws {
        try await store.saveToken("access-token-abc", service: testService, account: testAccount)
        let loaded = try await store.loadToken(service: testService, account: testAccount)
        XCTAssertEqual(loaded, "access-token-abc")
    }

    func test_load_nonexistent_token_returns_nil() async throws {
        let loaded = try await store.loadToken(service: "com.stratus.nonexistent", account: "ghost")
        XCTAssertNil(loaded)
    }

    func test_overwrite_token() async throws {
        try await store.saveToken("first-token", service: testService, account: testAccount)
        try await store.saveToken("second-token", service: testService, account: testAccount)
        let loaded = try await store.loadToken(service: testService, account: testAccount)
        XCTAssertEqual(loaded, "second-token")
    }

    func test_delete_token() async throws {
        try await store.saveToken("temp-token", service: testService, account: testAccount)
        try await store.deleteToken(service: testService, account: testAccount)
        let loaded = try await store.loadToken(service: testService, account: testAccount)
        XCTAssertNil(loaded)
    }

    func test_delete_nonexistent_token_no_throw() async throws {
        // Deleting a non-existent item must not throw
        XCTAssertNoThrow(try await store.deleteToken(service: "com.stratus.ghost", account: "ghost"))
    }

    // MARK: - Secret (Generic Password)

    func test_save_and_load_secret() async throws {
        let original = Data("secret-key-data".utf8)
        try await store.saveSecret(original, service: testService, account: testAccount)
        let loaded = try await store.loadSecret(service: testService, account: testAccount)
        XCTAssertEqual(loaded, original)
    }

    func test_load_nonexistent_secret_returns_nil() async throws {
        let loaded = try await store.loadSecret(service: "com.stratus.ghost2", account: "nobody")
        XCTAssertNil(loaded)
    }

    func test_overwrite_secret() async throws {
        try await store.saveSecret(Data("v1".utf8), service: testService, account: testAccount)
        try await store.saveSecret(Data("v2".utf8), service: testService, account: testAccount)
        let loaded = try await store.loadSecret(service: testService, account: testAccount)
        XCTAssertEqual(loaded, Data("v2".utf8))
    }

    func test_delete_secret() async throws {
        try await store.saveSecret(Data("secret".utf8), service: testService, account: testAccount)
        try await store.deleteSecret(service: testService, account: testAccount)
        let loaded = try await store.loadSecret(service: testService, account: testAccount)
        XCTAssertNil(loaded)
    }

    // MARK: - Binary data round-trip

    func test_binary_data_survives_round_trip() async throws {
        var bytes = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 { bytes[i] = UInt8(i) }
        let original = Data(bytes)
        try await store.saveSecret(original, service: testService, account: testAccount)
        let loaded = try await store.loadSecret(service: testService, account: testAccount)
        XCTAssertEqual(loaded, original)
    }

    // MARK: - Service name helpers

    func test_service_names_are_unique_per_provider() {
        let a = KeychainStore.ServiceName.accessToken(providerID: "gdrive", accountID: "acc1")
        let b = KeychainStore.ServiceName.accessToken(providerID: "dropbox", accountID: "acc1")
        XCTAssertNotEqual(a, b)
    }

    func test_service_names_are_unique_per_account() {
        let a = KeychainStore.ServiceName.accessToken(providerID: "gdrive", accountID: "acc1")
        let b = KeychainStore.ServiceName.accessToken(providerID: "gdrive", accountID: "acc2")
        XCTAssertNotEqual(a, b)
    }

    func test_access_and_refresh_token_service_names_differ() {
        let access = KeychainStore.ServiceName.accessToken(providerID: "onedrive", accountID: "x")
        let refresh = KeychainStore.ServiceName.refreshToken(providerID: "onedrive", accountID: "x")
        XCTAssertNotEqual(access, refresh)
    }

    func test_api_key_service_name_differs_from_access() {
        let access = KeychainStore.ServiceName.accessToken(providerID: "s3", accountID: "id")
        let apiKey = KeychainStore.ServiceName.apiKey(providerID: "s3", accountID: "id")
        XCTAssertNotEqual(access, apiKey)
    }

    func test_encryption_key_service_name_format() {
        let svc = KeychainStore.ServiceName.encryptionKey(vaultID: "vault-1")
        XCTAssertTrue(svc.contains("vault-1"), "Encryption key service name must embed vaultID")
    }

    func test_sftp_password_service_name_format() {
        let svc = KeychainStore.ServiceName.sftpPassword(accountID: "sftp-host")
        XCTAssertTrue(svc.contains("sftp-host"), "SFTP password service name must embed accountID")
    }
}
