import GRDB
import XCTest
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
        for i in 0 ..< 5 {
            try await store.saveSession(makeSession(id: "multi-session-\(i)", uploadID: "mpu-\(i)"))
        }
        let pending = try await store.loadPendingSessions()
        XCTAssertEqual(pending.count(where: { $0.id.hasPrefix("multi-session-") }), 5)
    }

    func test_loadSession_nonexistent_returnsNil() async throws {
        let result = try await store.loadSession("nonexistent-id")
        XCTAssertNil(result)
    }

    func test_pendingSessions_emptyInitially() async throws {
        let pending = try await store.loadPendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func test_saveSession_withPreCompletedChunks() async throws {
        var session = makeSession(id: "pre-complete", uploadID: "mpu-pre")
        session = UploadSession(
            id: session.id, fileURLString: session.fileURLString,
            providerID: session.providerID, accountID: session.accountID,
            remotePath: session.remotePath, uploadID: session.uploadID,
            fileSize: session.fileSize, fileChecksum: session.fileChecksum,
            chunkSize: session.chunkSize, totalChunks: session.totalChunks,
            completedChunks: [0, 1, 2], etags: [0: "a", 1: "b", 2: "c"]
        )
        try await store.saveSession(session)
        let loaded = try await store.loadSession("pre-complete")
        XCTAssertEqual(loaded?.completedChunks.sorted(), [0, 1, 2])
    }

    func test_markChunk_idempotent() async throws {
        let session = makeSession(id: "idem-session", uploadID: "mpu-idem")
        try await store.saveSession(session)
        try await store.markChunkComplete(sessionID: "idem-session", chunk: 5, etag: "etag5")
        try await store.markChunkComplete(sessionID: "idem-session", chunk: 5, etag: "etag5")
        let loaded = try await store.loadSession("idem-session")
        let chunks = loaded?.completedChunks.filter { $0 == 5 } ?? []
        XCTAssertEqual(chunks.count, 1, "Marking same chunk twice must not duplicate it")
    }

    func test_deleteNonexistent_noThrow() async throws {
        // Should not throw when deleting a session that doesn't exist
        try await store.deleteSession("never-existed")
    }

    func test_overwrite_updatesUploadID() async throws {
        let s1 = makeSession(id: "overwrite-id", uploadID: "mpu-v1")
        try await store.saveSession(s1)
        let s2 = makeSession(id: "overwrite-id", uploadID: "mpu-v2")
        try await store.saveSession(s2)
        let loaded = try await store.loadSession("overwrite-id")
        XCTAssertEqual(loaded?.uploadID, "mpu-v2", "Saving same session ID must overwrite the old entry")
    }

    func test_etags_persistedCorrectly() async throws {
        let session = makeSession(id: "etag-persist", uploadID: "mpu-etag")
        try await store.saveSession(session)
        for i in 0 ..< 5 {
            try await store.markChunkComplete(sessionID: "etag-persist", chunk: i, etag: "etag-\(i)")
        }
        let loaded = try await store.loadSession("etag-persist")
        XCTAssertEqual(loaded?.etags[0], "etag-0")
        XCTAssertEqual(loaded?.etags[4], "etag-4")
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
