import XCTest
import GRDB
@testable import StratusCore

final class ResumeStoreTests: XCTestCase {

    private var db: AppDatabase!
    private var store: ResumeStore!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        store = ResumeStore(db: db)
    }

    func test_saveAndLoadSession() async throws {
        let session = makeSession(id: "test-session-001", uploadID: "mpu-abc123")
        try await store.saveSession(session)
        let pending = try await store.loadPendingSessions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].id, "test-session-001")
        XCTAssertEqual(pending[0].uploadID, "mpu-abc123")
    }

    func test_markChunkComplete_updatesCompletedList() async throws {
        let session = makeSession(id: "test-session-002", uploadID: "mpu-xyz")
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
        let session = makeSession(id: "test-session-003", uploadID: "mpu-del")
        try await store.saveSession(session)
        try await store.deleteSession("test-session-003")
        let pending = try await store.loadPendingSessions()
        XCTAssertNil(pending.first { $0.id == "test-session-003" })
    }

    func test_multipleSessionsCoexist() async throws {
        for i in 0..<5 {
            try await store.saveSession(makeSession(id: "multi-session-\(i)", uploadID: "mpu-\(i)"))
        }
        let pending = try await store.loadPendingSessions()
        XCTAssertEqual(pending.filter { $0.id.hasPrefix("multi-session-") }.count, 5)
    }

    private func makeSession(id: String, uploadID: String) -> UploadSession {
        UploadSession(
            id: id,
            fileURLString: "/tmp/test.bin",
            providerID: "s3",
            accountID: "account1",
            remotePath: "/remote/test.bin",
            uploadID: uploadID,
            fileSize: 100_000_000,
            fileChecksum: "abc",
            chunkSize: 5_000_000,
            totalChunks: 20
        )
    }
}
