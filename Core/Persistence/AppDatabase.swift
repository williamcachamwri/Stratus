import Foundation
import GRDB
import os.log

// MARK: - AppDatabase

public actor AppDatabase {
    public static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fputs("Stratus database unavailable, falling back to in-memory store: \(error)\n", stderr)
            do {
                return try AppDatabase(inMemory: true)
            } catch {
                preconditionFailure("Stratus in-memory database fallback failed: \(error)")
            }
        }
    }()

    nonisolated let dbWriter: DatabaseWriter
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "Database")

    public init(path: String? = nil) throws {
        let url: URL
        if let path {
            url = URL(fileURLWithPath: path)
        } else {
            let stratusDir: URL
            if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FileProviderDomainStore.appGroupIdentifier) {
                stratusDir = groupURL.appendingPathComponent("Database", isDirectory: true)
            } else {
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? FileManager.default.temporaryDirectory
                stratusDir = appSupport.appendingPathComponent("Stratus", isDirectory: true)
            }
            try FileManager.default.createDirectory(at: stratusDir, withIntermediateDirectories: true)
            url = stratusDir.appendingPathComponent("stratus.db")
        }

        var config = Configuration()
        config.label = "Stratus"
        config.prepareDatabase { db in
            // WAL mode: < 5ms checkpoint latency
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA cache_size = -8000")  // 8 MB cache
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
        }

        dbWriter = try DatabasePool(path: url.path, configuration: config)
        try migrate()
    }

    // In-memory database for tests
    public static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(inMemory: true)
    }

    private init(inMemory: Bool) throws {
        var config = Configuration()
        config.label = "StratusTest"
        dbWriter = try DatabaseQueue(configuration: config)
        try migrate()
    }

    // MARK: - Migrations

    nonisolated private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("001_accounts") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    id TEXT PRIMARY KEY NOT NULL,
                    provider_id TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    email TEXT,
                    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
                )
            """)
        }
        migrator.registerMigration("002_upload_queue") { db in
            try db.execute(sql: """
                CREATE TABLE upload_sessions (
                    id TEXT PRIMARY KEY NOT NULL,
                    file_bookmark TEXT NOT NULL,
                    file_url_string TEXT NOT NULL,
                    provider_id TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    upload_id TEXT,
                    file_size INTEGER NOT NULL,
                    file_checksum TEXT NOT NULL,
                    chunk_size INTEGER NOT NULL,
                    total_chunks INTEGER NOT NULL,
                    completed_chunks TEXT NOT NULL DEFAULT '[]',
                    etags TEXT NOT NULL DEFAULT '{}',
                    state TEXT NOT NULL DEFAULT 'queued',
                    priority INTEGER NOT NULL DEFAULT 50,
                    retry_count INTEGER NOT NULL DEFAULT 0,
                    error_description TEXT,
                    created_at REAL NOT NULL DEFAULT (unixepoch('now')),
                    updated_at REAL NOT NULL DEFAULT (unixepoch('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_upload_sessions_state ON upload_sessions(state)")
            try db.execute(sql: "CREATE INDEX idx_upload_sessions_account ON upload_sessions(account_id)")
        }
        migrator.registerMigration("003_sync_state") { db in
            try db.execute(sql: """
                CREATE TABLE sync_pairs (
                    id TEXT PRIMARY KEY NOT NULL,
                    local_path TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    mode TEXT NOT NULL DEFAULT 'bidirectional',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    last_synced_at REAL,
                    created_at REAL NOT NULL DEFAULT (unixepoch('now'))
                )
            """)
            try db.execute(sql: """
                CREATE TABLE sync_state (
                    id TEXT PRIMARY KEY NOT NULL,
                    pair_id TEXT NOT NULL REFERENCES sync_pairs(id) ON DELETE CASCADE,
                    local_path TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    local_checksum TEXT,
                    remote_checksum TEXT,
                    local_size INTEGER,
                    remote_size INTEGER,
                    local_mod_date REAL,
                    remote_mod_date REAL,
                    last_synced_at REAL,
                    sync_status TEXT NOT NULL DEFAULT 'pending',
                    UNIQUE(pair_id, local_path)
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_sync_state_status ON sync_state(sync_status)")
        }
        migrator.registerMigration("004_resume_tokens") { db in
            try db.execute(sql: """
                CREATE TABLE block_manifests (
                    id TEXT PRIMARY KEY NOT NULL,
                    file_bookmark TEXT NOT NULL UNIQUE,
                    provider_id TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    block_map TEXT NOT NULL,
                    updated_at REAL NOT NULL DEFAULT (unixepoch('now'))
                )
            """)
        }
        migrator.registerMigration("005_provider_account_configs") { db in
            try db.execute(sql: """
                CREATE TABLE provider_account_configs (
                    account_id TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    provider_id TEXT NOT NULL,
                    config_json TEXT NOT NULL,
                    updated_at REAL NOT NULL DEFAULT (unixepoch('now'))
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_provider_account_configs_provider ON provider_account_configs(provider_id)")
        }

        try migrator.migrate(dbWriter)
    }

    // MARK: - Read/Write helpers

    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await dbWriter.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) async throws -> T {
        try await dbWriter.write(block)
    }
}
