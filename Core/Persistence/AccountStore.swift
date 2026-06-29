import Foundation
import GRDB
import os.log

// MARK: - AccountRecord (GRDB row mapping)

/// Internal GRDB record type — not exposed publicly; callers work with
/// `CloudAccount` directly.
private struct AccountRecord: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "accounts"

    var id: String
    var providerID: String
    var displayName: String
    var email: String?
    var createdAt: Date

    // MARK: Column mapping

    enum Columns: String, ColumnExpression {
        case id
        case providerID = "provider_id"
        case displayName = "display_name"
        case email
        case createdAt = "created_at"
    }

    init(row: Row) throws {
        id = row[Columns.id]
        providerID = row[Columns.providerID]
        displayName = row[Columns.displayName]
        email = row[Columns.email]
        // GRDB stores dates as Unix timestamps (REAL) per the schema.
        let rawDate: Double = row[Columns.createdAt]
        createdAt = Date(timeIntervalSince1970: rawDate)
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.providerID] = providerID
        container[Columns.displayName] = displayName
        container[Columns.email] = email
        container[Columns.createdAt] = createdAt.timeIntervalSince1970
    }

    // MARK: Conversion

    func toCloudAccount() -> CloudAccount {
        CloudAccount(
            id: id,
            providerID: providerID,
            displayName: displayName,
            email: email,
            createdAt: createdAt
        )
    }

    init(account: CloudAccount) {
        id = account.id
        providerID = account.providerID
        displayName = account.displayName
        email = account.email
        createdAt = account.createdAt
    }
}

// MARK: - AccountStoreError

public enum AccountStoreError: Error, Sendable {
    case accountNotFound(String)
    case databaseError(any Error)
}

// MARK: - AccountStore

/// Persists `CloudAccount` values in the shared SQLite database.
///
/// All writes are performed on the `AppDatabase.shared` actor and are
/// fully async/await — no direct GRDB calls leak outside this actor.
public actor AccountStore {
    public static let shared = AccountStore()

    private let database = AppDatabase.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "AccountStore")

    private init() {}

    // MARK: - Write

    /// Inserts or replaces the account record.
    public func save(_ account: CloudAccount) async throws {
        do {
            let record = AccountRecord(account: account)
            try await database.write { db in
                var r = record
                try r.save(db)
            }
            logger.debug("Saved account \(account.id) (\(account.providerID))")
        } catch {
            logger.error("Failed to save account \(account.id): \(error)")
            throw AccountStoreError.databaseError(error)
        }
    }

    /// Deletes the account with the given `id`.  No-ops if it does not exist.
    public func delete(id: String) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM accounts WHERE id = ?",
                    arguments: [id]
                )
            }
            logger.debug("Deleted account \(id)")
        } catch {
            logger.error("Failed to delete account \(id): \(error)")
            throw AccountStoreError.databaseError(error)
        }
    }

    // MARK: - Read

    /// Returns the `CloudAccount` with the given `id`, or `nil` if not found.
    public func load(id: String) async throws -> CloudAccount? {
        do {
            return try await database.read { db in
                let record = try AccountRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM accounts WHERE id = ?",
                    arguments: [id]
                )
                return record?.toCloudAccount()
            }
        } catch {
            logger.error("Failed to load account \(id): \(error)")
            throw AccountStoreError.databaseError(error)
        }
    }

    /// Returns all persisted accounts ordered by `created_at` ascending.
    public func loadAll() async throws -> [CloudAccount] {
        do {
            return try await database.read { db in
                let records = try AccountRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM accounts ORDER BY created_at ASC"
                )
                return records.map { $0.toCloudAccount() }
            }
        } catch {
            logger.error("Failed to load all accounts: \(error)")
            throw AccountStoreError.databaseError(error)
        }
    }

    /// Returns all accounts belonging to the given provider.
    public func loadAll(providerID: String) async throws -> [CloudAccount] {
        do {
            return try await database.read { db in
                let records = try AccountRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM accounts WHERE provider_id = ? ORDER BY created_at ASC",
                    arguments: [providerID]
                )
                return records.map { $0.toCloudAccount() }
            }
        } catch {
            logger.error("Failed to load accounts for provider \(providerID): \(error)")
            throw AccountStoreError.databaseError(error)
        }
    }
}
