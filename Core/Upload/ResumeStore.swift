import Foundation
import GRDB
import os.log

// MARK: - ResumeStore
// SQLite-backed crash-proof persistence for upload sessions.
// Survives app crashes, force quits, and system restarts.

public actor ResumeStore {
    public static let shared = ResumeStore()
    private let db: AppDatabase
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ResumeStore")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(db: AppDatabase = AppDatabase.shared) {
        self.db = db
    }

    public nonisolated static func makeBookmarkData(for url: URL) throws -> Data? {
        #if os(macOS)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return nil
        #endif
    }

    public nonisolated func resolvedFileURL(for session: UploadSession) throws -> URL {
        #if os(macOS)
        if let bookmark = session.fileBookmark, !bookmark.isEmpty {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw UploadError.fileChanged(url) }
            return url
        }
        #endif
        return URL(fileURLWithPath: session.fileURLString)
    }

    // MARK: - Session Management

    public func saveSession(_ session: UploadSession) async throws {
        let etagsJSON = try encoder.encode(session.etags)
        let chunksJSON = try encoder.encode(session.completedChunks)
        let etagsStr = String(data: etagsJSON, encoding: .utf8) ?? "{}"
        let chunksStr = String(data: chunksJSON, encoding: .utf8) ?? "[]"
        let now = Date().timeIntervalSince1970

        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO upload_sessions
                  (id, file_bookmark, file_url_string, provider_id, account_id, remote_path,
                   upload_id, file_size, file_checksum, chunk_size, total_chunks,
                   completed_chunks, etags, state, retry_count, error_description,
                   created_at, updated_at)
                VALUES
                  (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  upload_id = excluded.upload_id,
                  completed_chunks = excluded.completed_chunks,
                  etags = excluded.etags,
                  state = excluded.state,
                  retry_count = excluded.retry_count,
                  error_description = excluded.error_description,
                  updated_at = excluded.updated_at
                """,
                arguments: [
                    session.id,
                    session.fileBookmark.map { $0.base64EncodedString() } ?? "",
                    session.fileURLString,
                    session.providerID,
                    session.accountID,
                    session.remotePath,
                    session.uploadID,
                    session.fileSize,
                    session.fileChecksum,
                    session.chunkSize,
                    session.totalChunks,
                    chunksStr,
                    etagsStr,
                    session.state,
                    session.retryCount,
                    session.errorDescription,
                    session.createdAt.timeIntervalSince1970,
                    now
                ]
            )
        }
        logger.debug("Saved session \(session.id) (\(session.completedChunks.count)/\(session.totalChunks) chunks)")
    }

    public func markChunkComplete(sessionID: String, chunk: Int, etag: String) async throws {
        // Atomic update: append chunk number + set etag
        try await db.write { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT completed_chunks, etags FROM upload_sessions WHERE id = ?",
                arguments: [sessionID]
            ) else { return }

            let chunksStr = (row["completed_chunks"] as? String) ?? "[]"
            let etagsStr = (row["etags"] as? String) ?? "{}"

            var chunks = (try? JSONDecoder().decode([Int].self, from: Data(chunksStr.utf8))) ?? []
            if !chunks.contains(chunk) {
                chunks.append(chunk)
                chunks.sort()
            }

            var etagMap = (try? JSONDecoder().decode([Int: String].self, from: Data(etagsStr.utf8))) ?? [:]
            etagMap[chunk] = etag

            let newChunksJSON = (try? JSONEncoder().encode(chunks)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let newEtagsJSON = (try? JSONEncoder().encode(etagMap)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            try database.execute(sql: """
                UPDATE upload_sessions
                SET completed_chunks = ?, etags = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [newChunksJSON, newEtagsJSON, Date().timeIntervalSince1970, sessionID]
            )
        }
    }

    public func loadSession(_ id: String) async throws -> UploadSession? {
        try await db.read { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT * FROM upload_sessions WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return try self.sessionFromRow(row)
        }
    }

    public func loadPendingSessions() async throws -> [UploadSession] {
        try await db.read { database in
            let rows = try Row.fetchAll(database,
                sql: "SELECT * FROM upload_sessions WHERE state IN ('uploading', 'paused', 'queued') ORDER BY created_at ASC"
            )
            return rows.compactMap { try? self.sessionFromRow($0) }
        }
    }

    public func allSessions() async throws -> [UploadSession] {
        try await db.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT * FROM upload_sessions ORDER BY created_at DESC")
            return rows.compactMap { try? self.sessionFromRow($0) }
        }
    }

    public func updateSessionState(_ id: String, state: String, error: String? = nil) async throws {
        try await db.write { database in
            try database.execute(sql: """
                UPDATE upload_sessions SET state = ?, error_description = ?, updated_at = ? WHERE id = ?
                """,
                arguments: [state, error, Date().timeIntervalSince1970, id]
            )
        }
    }

    public func deleteSession(_ sessionID: String) async throws {
        try await db.write { database in
            try database.execute(sql: "DELETE FROM upload_sessions WHERE id = ?", arguments: [sessionID])
        }
    }

    public func deleteCompletedSessions() async throws {
        try await db.write { database in
            try database.execute(sql: "DELETE FROM upload_sessions WHERE state = 'completed'")
        }
    }

    // MARK: - Block Manifests

    public func saveBlockManifest(_ manifest: BlockMap, fileURL: URL, providerID: String, accountID: String, remotePath: String) async throws {
        let manifestJSON = try encoder.encode(manifest)
        let manifestStr = String(data: manifestJSON, encoding: .utf8) ?? "{}"
        let bookmarkStr = bookmarkKey(for: fileURL)

        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO block_manifests (id, file_bookmark, provider_id, account_id, remote_path, block_map, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(file_bookmark) DO UPDATE SET
                  block_map = excluded.block_map,
                  updated_at = excluded.updated_at
                """,
                arguments: [UUID().uuidString, bookmarkStr, providerID, accountID, remotePath, manifestStr, Date().timeIntervalSince1970]
            )
        }
    }

    public func loadBlockManifest(fileURL: URL, providerID: String) async throws -> BlockMap? {
        let bookmarkStr = bookmarkKey(for: fileURL)
        return try await db.read { database in
            guard let row = try Row.fetchOne(database,
                sql: "SELECT block_map FROM block_manifests WHERE file_bookmark = ? AND provider_id = ?",
                arguments: [bookmarkStr, providerID]
            ), let mapStr = row["block_map"] as? String,
               let mapData = mapStr.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(BlockMap.self, from: mapData)
        }
    }

    // MARK: - Private

    private nonisolated func bookmarkKey(for url: URL) -> String {
        if let bookmark = try? Self.makeBookmarkData(for: url), !bookmark.isEmpty {
            return bookmark.base64EncodedString()
        }
        return url.path
    }

    private nonisolated func sessionFromRow(_ row: Row) throws -> UploadSession {
        let chunksStr = (row["completed_chunks"] as? String) ?? "[]"
        let etagsStr = (row["etags"] as? String) ?? "{}"
        let chunks = (try? JSONDecoder().decode([Int].self, from: Data(chunksStr.utf8))) ?? []
        let etags = (try? JSONDecoder().decode([Int: String].self, from: Data(etagsStr.utf8))) ?? [:]
        let createdAt = Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0)
        let updatedAt = Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? 0)
        let bookmarkStr = (row["file_bookmark"] as? String) ?? ""
        let bookmark = Data(base64Encoded: bookmarkStr)

        return UploadSession(
            id: (row["id"] as? String) ?? "",
            fileBookmark: bookmark,
            fileURLString: (row["file_url_string"] as? String) ?? "",
            providerID: (row["provider_id"] as? String) ?? "",
            accountID: (row["account_id"] as? String) ?? "",
            remotePath: (row["remote_path"] as? String) ?? "",
            uploadID: row["upload_id"] as? String,
            fileSize: (row["file_size"] as? Int64) ?? 0,
            fileChecksum: (row["file_checksum"] as? String) ?? "",
            chunkSize: (row["chunk_size"] as? Int) ?? 0,
            totalChunks: (row["total_chunks"] as? Int) ?? 0,
            completedChunks: chunks,
            etags: etags,
            state: (row["state"] as? String) ?? "unknown",
            retryCount: (row["retry_count"] as? Int) ?? 0,
            errorDescription: row["error_description"] as? String,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
