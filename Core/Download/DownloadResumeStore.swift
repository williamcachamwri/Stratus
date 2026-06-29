import Foundation
import GRDB
import os.log

// MARK: - DownloadSession (persisted form)

/// A flat, Codable snapshot of a download task suitable for storage in SQLite.
/// One row ↔ one DownloadTask. Fields that change frequently (completedSegments,
/// state) are updated in-place with ON CONFLICT … DO UPDATE.
public struct DownloadSession: Sendable, Codable {
    public let id: String               // UUID string; matches DownloadTask.id
    public let providerID: String
    public let accountID: String
    public let remotePath: String
    public let destinationPath: String  // local URL.path for the finished file
    public let stagingPath: String      // local URL.path for the staging file
    public let expectedSize: Int64      // 0 when unknown
    public var completedSegmentIndices: [Int]   // sorted list of finished segment indices
    public var highWaterOffset: Int64           // highest byte offset confirmed written
    public var state: String                    // "queued" | "downloading" | "paused" | "completed" | "failed" | "cancelled"
    public var retryCount: Int
    public var errorDescription: String?
    public var priority: Int            // DownloadPriority.rawValue
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        providerID: String,
        accountID: String,
        remotePath: String,
        destinationPath: String,
        stagingPath: String,
        expectedSize: Int64,
        completedSegmentIndices: [Int] = [],
        highWaterOffset: Int64 = 0,
        state: String = "queued",
        retryCount: Int = 0,
        errorDescription: String? = nil,
        priority: Int = DownloadPriority.normal.rawValue,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.providerID = providerID
        self.accountID = accountID
        self.remotePath = remotePath
        self.destinationPath = destinationPath
        self.stagingPath = stagingPath
        self.expectedSize = expectedSize
        self.completedSegmentIndices = completedSegmentIndices
        self.highWaterOffset = highWaterOffset
        self.state = state
        self.retryCount = retryCount
        self.errorDescription = errorDescription
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: Derived helpers

    public var resumeToken: DownloadResumeToken {
        DownloadResumeToken(sessionID: id, resumeOffset: highWaterOffset)
    }

    public var completedSegmentSet: Set<Int> {
        Set(completedSegmentIndices)
    }
}

// MARK: - DownloadResumeStore errors

public enum DownloadResumeStoreError: Error, Sendable {
    case sessionNotFound(String)
    case encodingFailed(String)
    case decodingFailed(String)
}

// MARK: - DownloadResumeStore

/// SQLite-backed (via AppDatabase / GRDB) persistence for download sessions.
///
/// All public methods are `async throws` so callers can use structured
/// concurrency. The actor isolation ensures that concurrent calls to e.g.
/// `markSegmentComplete` and `updateState` are serialised safely.
public actor DownloadResumeStore {

    // MARK: Shared instance

    public static let shared = DownloadResumeStore()

    // MARK: Dependencies

    private let db: AppDatabase
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DownloadResumeStore")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Init

    public init(db: AppDatabase = AppDatabase.shared) {
        self.db = db
    }

    // MARK: - Schema Bootstrap

    /// Creates the `download_sessions` table if it does not already exist.
    /// Call this once during app startup (e.g. from DownloadEngine.start()).
    public func prepareSchema() async throws {
        try await db.write { database in
            try database.execute(sql: """
                CREATE TABLE IF NOT EXISTS download_sessions (
                    id                       TEXT    PRIMARY KEY NOT NULL,
                    provider_id              TEXT    NOT NULL,
                    account_id               TEXT    NOT NULL,
                    remote_path              TEXT    NOT NULL,
                    destination_path         TEXT    NOT NULL,
                    staging_path             TEXT    NOT NULL,
                    expected_size            INTEGER NOT NULL DEFAULT 0,
                    completed_segment_indices TEXT   NOT NULL DEFAULT '[]',
                    high_water_offset        INTEGER NOT NULL DEFAULT 0,
                    state                    TEXT    NOT NULL DEFAULT 'queued',
                    retry_count              INTEGER NOT NULL DEFAULT 0,
                    error_description        TEXT,
                    priority                 INTEGER NOT NULL DEFAULT 50,
                    created_at               REAL    NOT NULL DEFAULT (unixepoch('now')),
                    updated_at               REAL    NOT NULL DEFAULT (unixepoch('now'))
                )
            """)
            try database.execute(sql:
                "CREATE INDEX IF NOT EXISTS idx_dl_sessions_state   ON download_sessions(state)"
            )
            try database.execute(sql:
                "CREATE INDEX IF NOT EXISTS idx_dl_sessions_account ON download_sessions(account_id)"
            )
        }
        logger.debug("download_sessions schema ready")
    }

    // MARK: - CRUD

    /// Insert or update a complete session snapshot.
    public func upsert(_ session: DownloadSession) async throws {
        let indicesJSON: String
        do {
            let data = try encoder.encode(session.completedSegmentIndices)
            indicesJSON = String(data: data, encoding: .utf8) ?? "[]"
        } catch {
            throw DownloadResumeStoreError.encodingFailed(error.localizedDescription)
        }

        let now = Date().timeIntervalSince1970

        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO download_sessions
                  (id, provider_id, account_id, remote_path, destination_path, staging_path,
                   expected_size, completed_segment_indices, high_water_offset, state,
                   retry_count, error_description, priority, created_at, updated_at)
                VALUES
                  (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  completed_segment_indices = excluded.completed_segment_indices,
                  high_water_offset         = excluded.high_water_offset,
                  state                     = excluded.state,
                  retry_count               = excluded.retry_count,
                  error_description         = excluded.error_description,
                  updated_at                = excluded.updated_at
                """,
                arguments: [
                    session.id,
                    session.providerID,
                    session.accountID,
                    session.remotePath,
                    session.destinationPath,
                    session.stagingPath,
                    session.expectedSize,
                    indicesJSON,
                    session.highWaterOffset,
                    session.state,
                    session.retryCount,
                    session.errorDescription,
                    session.priority,
                    session.createdAt.timeIntervalSince1970,
                    now
                ]
            )
        }
        logger.debug("Upserted session \(session.id) state=\(session.state) segments=\(session.completedSegmentIndices.count)")
    }

    /// Atomically mark a single segment as complete and advance the high-water offset.
    public func markSegmentComplete(
        sessionID: String,
        segmentIndex: Int,
        newHighWaterOffset: Int64
    ) async throws {
        try await db.write { [encoder] database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT completed_segment_indices, high_water_offset FROM download_sessions WHERE id = ?",
                arguments: [sessionID]
            ) else {
                throw DownloadResumeStoreError.sessionNotFound(sessionID)
            }

            let existingJSON = (row["completed_segment_indices"] as? String) ?? "[]"
            var indices = (try? JSONDecoder().decode([Int].self, from: Data(existingJSON.utf8))) ?? []

            if !indices.contains(segmentIndex) {
                indices.append(segmentIndex)
                indices.sort()
            }

            let existingHW = (row["high_water_offset"] as? Int64) ?? 0
            let hwm = max(existingHW, newHighWaterOffset)

            let newJSON: String
            do {
                let data = try encoder.encode(indices)
                newJSON = String(data: data, encoding: .utf8) ?? "[]"
            } catch {
                throw DownloadResumeStoreError.encodingFailed(error.localizedDescription)
            }

            try database.execute(sql: """
                UPDATE download_sessions
                SET completed_segment_indices = ?,
                    high_water_offset         = ?,
                    updated_at                = ?
                WHERE id = ?
                """,
                arguments: [newJSON, hwm, Date().timeIntervalSince1970, sessionID]
            )
        }
    }

    /// Update just the state and optional error string.
    public func updateState(
        sessionID: String,
        state: String,
        errorDescription: String? = nil
    ) async throws {
        try await db.write { database in
            try database.execute(sql: """
                UPDATE download_sessions
                SET state = ?, error_description = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [state, errorDescription, Date().timeIntervalSince1970, sessionID]
            )
        }
    }

    /// Increment the retry counter for a session.
    public func incrementRetryCount(sessionID: String) async throws {
        try await db.write { database in
            try database.execute(sql: """
                UPDATE download_sessions
                SET retry_count = retry_count + 1, updated_at = ?
                WHERE id = ?
                """,
                arguments: [Date().timeIntervalSince1970, sessionID]
            )
        }
    }

    // MARK: - Queries

    /// Load a single session by ID.
    public func load(sessionID: String) async throws -> DownloadSession? {
        try await db.read { [self] database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM download_sessions WHERE id = ?",
                arguments: [sessionID]
            ) else { return nil }
            return try self.sessionFromRow(row)
        }
    }

    /// Load all sessions that can be resumed (paused, downloading, or queued
    /// with partial progress). Ordered oldest-first so we resume in submission order.
    public func loadResumableSessions() async throws -> [DownloadSession] {
        try await db.read { [self] database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT * FROM download_sessions
                    WHERE state IN ('queued', 'downloading', 'paused')
                    ORDER BY priority DESC, created_at ASC
                    """
            )
            return rows.compactMap { try? self.sessionFromRow($0) }
        }
    }

    /// Load all sessions (useful for a UI download manager screen).
    public func loadAll() async throws -> [DownloadSession] {
        try await db.read { [self] database in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT * FROM download_sessions ORDER BY created_at DESC"
            )
            return rows.compactMap { try? self.sessionFromRow($0) }
        }
    }

    // MARK: - Deletion

    /// Remove a session record (call after successful completion or explicit user cancellation).
    public func delete(sessionID: String) async throws {
        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM download_sessions WHERE id = ?",
                arguments: [sessionID]
            )
        }
        logger.debug("Deleted session \(sessionID)")
    }

    /// Purge all terminal (completed / cancelled) sessions to reclaim space.
    public func deleteTerminalSessions() async throws {
        try await db.write { database in
            try database.execute(
                sql: "DELETE FROM download_sessions WHERE state IN ('completed', 'cancelled')"
            )
        }
        logger.debug("Purged terminal download sessions")
    }

    // MARK: - Private deserialisation

    private nonisolated func sessionFromRow(_ row: Row) throws -> DownloadSession {
        let indicesJSON = (row["completed_segment_indices"] as? String) ?? "[]"
        let indices = (try? JSONDecoder().decode([Int].self, from: Data(indicesJSON.utf8))) ?? []
        let createdAt = Date(timeIntervalSince1970: (row["created_at"] as? Double) ?? 0)
        let updatedAt = Date(timeIntervalSince1970: (row["updated_at"] as? Double) ?? 0)

        return DownloadSession(
            id:                      (row["id"]               as? String) ?? "",
            providerID:              (row["provider_id"]       as? String) ?? "",
            accountID:               (row["account_id"]        as? String) ?? "",
            remotePath:              (row["remote_path"]       as? String) ?? "",
            destinationPath:         (row["destination_path"]  as? String) ?? "",
            stagingPath:             (row["staging_path"]      as? String) ?? "",
            expectedSize:            (row["expected_size"]     as? Int64)  ?? 0,
            completedSegmentIndices: indices,
            highWaterOffset:         (row["high_water_offset"] as? Int64)  ?? 0,
            state:                   (row["state"]             as? String) ?? "unknown",
            retryCount:              (row["retry_count"]       as? Int)    ?? 0,
            errorDescription:         row["error_description"] as? String,
            priority:                (row["priority"]          as? Int)    ?? DownloadPriority.normal.rawValue,
            createdAt:               createdAt,
            updatedAt:               updatedAt
        )
    }
}
