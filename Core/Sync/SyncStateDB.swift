import Foundation
import GRDB
import os.log

// MARK: - SyncFileRecord

public struct SyncFileRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "sync_file_state"

    var pairID: String
    var remotePath: String
    var localPath: String
    var localModifiedAt: Date
    var remoteModifiedAt: Date
    var localSize: Int64
    var remoteSize: Int64
    var localChecksum: String?
    var remoteChecksum: String?
    var syncedAt: Date
    var syncDirection: String // "upload" | "download"
}

// MARK: - SyncStateDB

public actor SyncStateDB {
    private let pool: DatabasePool
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SyncStateDB")

    public init(pool: DatabasePool) async throws {
        self.pool = pool
        try await migrate()
    }

    // MARK: - Migration

    private func migrate() async throws {
        try await pool.write { db in
            try db.create(table: "sync_file_state", ifNotExists: true) { t in
                t.primaryKey(["pairID", "remotePath"])
                t.column("pairID", .text).notNull()
                t.column("remotePath", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("localModifiedAt", .datetime).notNull()
                t.column("remoteModifiedAt", .datetime).notNull()
                t.column("localSize", .integer).notNull()
                t.column("remoteSize", .integer).notNull()
                t.column("localChecksum", .text)
                t.column("remoteChecksum", .text)
                t.column("syncedAt", .datetime).notNull()
                t.column("syncDirection", .text).notNull()
            }
            try db.create(
                index: "sync_file_state_pair",
                on: "sync_file_state",
                columns: ["pairID"],
                ifNotExists: true
            )
        }
    }

    // MARK: - Public API

    public func recordSync(
        pairID: UUID,
        localURL: URL,
        remotePath: CloudPath,
        localItem: CloudFileItem,
        remoteItem: CloudFileItem,
        direction: String
    ) async throws {
        let record = SyncFileRecord(
            pairID: pairID.uuidString,
            remotePath: remotePath.path,
            localPath: localURL.path,
            localModifiedAt: localItem.modificationDate ?? Date(),
            remoteModifiedAt: remoteItem.modificationDate ?? Date(),
            localSize: localItem.size ?? 0,
            remoteSize: remoteItem.size ?? 0,
            localChecksum: localItem.etag,
            remoteChecksum: remoteItem.etag,
            syncedAt: Date(),
            syncDirection: direction
        )
        try await pool.write { db in
            try record.upsert(db)
        }
    }

    public func lastSyncRecord(pairID: UUID, remotePath: CloudPath) async throws -> SyncFileRecord? {
        try await pool.read { db in
            try SyncFileRecord
                .filter(Column("pairID") == pairID.uuidString && Column("remotePath") == remotePath.path)
                .fetchOne(db)
        }
    }

    public func allRecords(pairID: UUID) async throws -> [SyncFileRecord] {
        try await pool.read { db in
            try SyncFileRecord
                .filter(Column("pairID") == pairID.uuidString)
                .fetchAll(db)
        }
    }

    public func deleteRecord(pairID: UUID, remotePath: CloudPath) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM sync_file_state WHERE pairID = ? AND remotePath = ?",
                arguments: [pairID.uuidString, remotePath.path]
            )
        }
    }

    public func deleteAllRecords(pairID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM sync_file_state WHERE pairID = ?",
                arguments: [pairID.uuidString]
            )
        }
    }

    // MARK: - Conflict Detection

    public func isConflict(
        pairID: UUID,
        localURL: URL,
        remotePath: CloudPath,
        localModDate: Date,
        remoteModDate: Date
    ) async throws -> Bool {
        guard let record = try await lastSyncRecord(pairID: pairID, remotePath: remotePath) else {
            return false // No prior sync state = not a conflict
        }
        let localChanged = abs(localModDate.timeIntervalSince(record.localModifiedAt)) > 1
        let remoteChanged = abs(remoteModDate.timeIntervalSince(record.remoteModifiedAt)) > 1
        return localChanged && remoteChanged
    }
}
