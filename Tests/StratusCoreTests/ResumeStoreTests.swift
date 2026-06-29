import XCTest
import GRDB
@testable import StratusCore

final class ResumeStoreTests: XCTestCase {

    private var db: AppDatabase!
    private var store: ResumeStore!

    override func setUp() async throws {
        db = try await AppDatabase.makeInMemory()
        store = ResumeStore(database: db)
    }

    func test_saveAndLoadSession() async throws {
        let session = UploadSession(
            id: "test-session-001",
            fileURL: URL(fileURLWithPath: "/tmp/test.bin"),
            remotePath: CloudPath("/remote/test.bin"),
            accountID: "account1",
            totalSize: 100_000_000,
            chunkSize: 5_000_000,
            providerID: "s3",
            uploadID: "mpu-abc123",
            completedChunks: [],
            etags: [:]
        )
        try await store.saveSession(session)
        let pending = try await store.loadPendingSessions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].id, "test-session-001")
        XCTAssertEqual(pending[0].uploadID, "mpu-abc123")
    }

    func test_markChunkComplete_updatesCompletedList() async throws {
        let session = UploadSession(
            id: "test-session-002",
            fileURL: URL(fileURLWithPath: "/tmp/test2.bin"),
            remotePath: CloudPath("/remote/test2.bin"),
            accountID: "account1",
            totalSize: 20_000_000,
            chunkSize: 5_000_000,
            providerID: "s3",
            uploadID: "mpu-xyz",
            completedChunks: [],
            etags: [:]
        )
        try await store.saveSession(session)
        try await store.markChunkComplete(sessionID: "test-session-002", chunk: 0, etag: "etag0")
        try await store.markChunkComplete(sessionID: "test-session-002", chunk: 1, etag: "etag1")
        let pending = try await store.loadPendingSessions()
        let loaded = try XCTUnwrap(pending.first { $0.id == "test-session-002" })
        XCTAssertTrue(loaded.completedChunks.contains(0))
        XCTAssertTrue(loaded.completedChunks.contains(1))
        XCTAssertEqual(loaded.etags[0], "etag0")
        XCTAssertEqual(loaded.etags[1], "etag1")
    }

    func test_deleteSession_removesFromPending() async throws {
        let session = UploadSession(
            id: "test-session-003",
            fileURL: URL(fileURLWithPath: "/tmp/test3.bin"),
            remotePath: CloudPath("/remote/test3.bin"),
            accountID: "account1",
            totalSize: 5_000_000,
            chunkSize: 5_000_000,
            providerID: "s3",
            uploadID: "mpu-del",
            completedChunks: [],
            etags: [:]
        )
        try await store.saveSession(session)
        try await store.deleteSession("test-session-003")
        let pending = try await store.loadPendingSessions()
        XCTAssertNil(pending.first { $0.id == "test-session-003" })
    }

    func test_multipleSessionsCoexist() async throws {
        for i in 0..<5 {
            let session = UploadSession(
                id: "multi-session-\(i)",
                fileURL: URL(fileURLWithPath: "/tmp/multi\(i).bin"),
                remotePath: CloudPath("/remote/multi\(i).bin"),
                accountID: "acct",
                totalSize: 10_000_000,
                chunkSize: 5_000_000,
                providerID: "gdrive",
                uploadID: "mpu-\(i)",
                completedChunks: [],
                etags: [:]
            )
            try await store.saveSession(session)
        }
        let pending = try await store.loadPendingSessions()
        XCTAssertEqual(pending.filter { $0.id.hasPrefix("multi-session-") }.count, 5)
    }
}
