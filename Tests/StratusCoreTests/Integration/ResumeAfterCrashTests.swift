import XCTest
import GRDB
@testable import StratusCore

// Tests that an upload session survives a simulated crash (process kill) and
// can be resumed from the exact byte offset where it was interrupted.

final class ResumeAfterCrashTests: XCTestCase {

    private var db: AppDatabase!
    private var store: ResumeStore!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        store = ResumeStore(db: db)
        try await super.setUp()
    }

    // MARK: - Session persists to SQLite

    func test_session_persists_after_save() async throws {
        let session = makeSession(id: "crash-001", uploadID: "mpu-crash-001", totalChunks: 10)
        try await store.saveSession(session)

        let pending = try await store.loadPendingSessions()
        let found = pending.first { $0.id == "crash-001" }
        XCTAssertNotNil(found, "Session must be loadable after save")
        XCTAssertEqual(found?.uploadID, "mpu-crash-001")
    }

    // MARK: - Crash at chunk 5/10: resume completes correctly

    func test_resume_from_chunk_5_of_10() async throws {
        let session = makeSession(id: "crash-002", uploadID: "mpu-crash-002", totalChunks: 10)
        try await store.saveSession(session)

        // Simulate completing chunks 0-4 before crash
        for i in 0..<5 {
            try await store.markChunkComplete(sessionID: "crash-002", chunk: i, etag: "etag-\(i)")
        }

        // "Crash" — reload from store (simulates process restart)
        let recovered = try await store.loadSession("crash-002")
        let recoveredSession = try XCTUnwrap(recovered)

        XCTAssertEqual(recoveredSession.completedChunks.sorted(), [0, 1, 2, 3, 4])
        XCTAssertEqual(recoveredSession.totalChunks, 10)

        // Resume: complete remaining chunks 5-9
        for i in 5..<10 {
            try await store.markChunkComplete(sessionID: "crash-002", chunk: i, etag: "etag-\(i)")
        }

        let completed = try await store.loadSession("crash-002")
        XCTAssertEqual(completed?.completedChunks.count, 10, "All 10 chunks must be marked complete after resume")
    }

    // MARK: - Changed file invalidates resume token

    func test_changed_file_checksum_invalidates_session() async throws {
        let original = makeSession(id: "crash-003", uploadID: "mpu-crash-003", checksum: "sha256-aaa")
        try await store.saveSession(original)
        try await store.markChunkComplete(sessionID: "crash-003", chunk: 0, etag: "etag-0")

        // File changed: new session with different checksum replaces the old one
        let changed = makeSession(id: "crash-003", uploadID: "mpu-crash-003-new", checksum: "sha256-bbb")
        try await store.saveSession(changed)

        let loaded = try await store.loadSession("crash-003")
        XCTAssertEqual(loaded?.uploadID, "mpu-crash-003-new", "New session must overwrite stale one")
        XCTAssertTrue(loaded?.completedChunks.isEmpty ?? false, "Changed file must reset completed chunks")
    }

    // MARK: - Multiple sessions coexist and resume independently

    func test_multiple_sessions_resume_independently() async throws {
        for i in 0..<5 {
            let s = makeSession(id: "multi-crash-\(i)", uploadID: "mpu-multi-\(i)", totalChunks: 4)
            try await store.saveSession(s)
        }
        for i in 0..<5 {
            try await store.markChunkComplete(sessionID: "multi-crash-\(i)", chunk: 0, etag: "e-\(i)-0")
            try await store.markChunkComplete(sessionID: "multi-crash-\(i)", chunk: 1, etag: "e-\(i)-1")
        }

        for i in 0..<5 {
            let loaded = try await store.loadSession("multi-crash-\(i)")
            XCTAssertEqual(loaded?.completedChunks.sorted(), [0, 1], "Session \(i) must have exactly chunks 0,1")
        }
    }

    // MARK: - Completed session cleanup

    func test_session_deleted_after_completion() async throws {
        let session = makeSession(id: "crash-clean", uploadID: "mpu-clean", totalChunks: 2)
        try await store.saveSession(session)
        try await store.markChunkComplete(sessionID: "crash-clean", chunk: 0, etag: "a")
        try await store.markChunkComplete(sessionID: "crash-clean", chunk: 1, etag: "b")

        // Delete after a successful complete call
        try await store.deleteSession("crash-clean")

        let loaded = try await store.loadSession("crash-clean")
        XCTAssertNil(loaded, "Deleted session must not appear in store")
    }

    // MARK: - Helpers

    private func makeSession(id: String, uploadID: String, totalChunks: Int = 10, checksum: String = "sha256-default") -> UploadSession {
        UploadSession(
            id: id,
            fileURLString: "/tmp/crash-test.bin",
            providerID: "s3",
            accountID: "crash-account",
            remotePath: "/remote/crash-test.bin",
            uploadID: uploadID,
            fileSize: Int64(totalChunks) * 5_000_000,
            fileChecksum: checksum,
            chunkSize: 5_000_000,
            totalChunks: totalChunks
        )
    }
}
