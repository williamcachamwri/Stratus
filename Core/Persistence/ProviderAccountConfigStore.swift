import Foundation
import GRDB
import os.log

// MARK: - ProviderAccountConfig

/// Non-secret connection settings required to construct a real provider
/// instance for a persisted account. Secrets remain in Keychain via
/// `CredentialVault`.
public struct ProviderAccountConfig: Codable, Equatable, Sendable {
    public let accountID: String
    public let providerID: String
    public var endpointURL: String?
    public var region: String?
    public var bucket: String?
    public var host: String?
    public var port: Int?
    public var username: String?
    public var basePath: String?
    public var useTLS: Bool
    public var usePathStyleURL: Bool
    public var useTransferAcceleration: Bool

    public init(
        accountID: String,
        providerID: String,
        endpointURL: String? = nil,
        region: String? = nil,
        bucket: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        username: String? = nil,
        basePath: String? = nil,
        useTLS: Bool = false,
        usePathStyleURL: Bool = false,
        useTransferAcceleration: Bool = false
    ) {
        self.accountID = accountID
        self.providerID = providerID
        self.endpointURL = endpointURL
        self.region = region
        self.bucket = bucket
        self.host = host
        self.port = port
        self.username = username
        self.basePath = basePath
        self.useTLS = useTLS
        self.usePathStyleURL = usePathStyleURL
        self.useTransferAcceleration = useTransferAcceleration
    }
}

// MARK: - ProviderAccountConfigStoreError

public enum ProviderAccountConfigStoreError: Error, Sendable {
    case databaseError(any Error)
    case encodingFailed(any Error)
    case decodingFailed(any Error)
}

// MARK: - ProviderAccountConfigRecord

private struct ProviderAccountConfigRecord: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "provider_account_configs"

    var accountID: String
    var providerID: String
    var configJSON: String
    var updatedAt: Date

    enum Columns: String, ColumnExpression {
        case accountID = "account_id"
        case providerID = "provider_id"
        case configJSON = "config_json"
        case updatedAt = "updated_at"
    }

    init(row: Row) throws {
        accountID = row[Columns.accountID]
        providerID = row[Columns.providerID]
        configJSON = row[Columns.configJSON]
        let rawDate: Double = row[Columns.updatedAt]
        updatedAt = Date(timeIntervalSince1970: rawDate)
    }

    init(config: ProviderAccountConfig, json: String, updatedAt: Date = Date()) {
        accountID = config.accountID
        providerID = config.providerID
        configJSON = json
        self.updatedAt = updatedAt
    }

    func encode(to container: inout PersistenceContainer) {
        container[Columns.accountID] = accountID
        container[Columns.providerID] = providerID
        container[Columns.configJSON] = configJSON
        container[Columns.updatedAt] = updatedAt.timeIntervalSince1970
    }
}

// MARK: - ProviderAccountConfigStore

public actor ProviderAccountConfigStore {
    public static let shared = ProviderAccountConfigStore()

    private let database = AppDatabase.shared
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ProviderAccountConfigStore")

    private init() {
        encoder.outputFormatting = [.sortedKeys]
    }

    public func save(_ config: ProviderAccountConfig) async throws {
        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw ProviderAccountConfigStoreError.encodingFailed(error)
        }

        guard let json = String(data: data, encoding: .utf8) else {
            throw ProviderAccountConfigStoreError.encodingFailed(EncodingError.invalidValue(
                config,
                EncodingError.Context(codingPath: [], debugDescription: "Provider config JSON was not UTF-8")
            ))
        }

        do {
            let record = ProviderAccountConfigRecord(config: config, json: json)
            try await database.write { db in
                var mutable = record
                try mutable.save(db)
            }
            logger.debug("Saved provider config for account \(config.accountID)")
        } catch {
            throw ProviderAccountConfigStoreError.databaseError(error)
        }
    }

    public func load(accountID: String) async throws -> ProviderAccountConfig? {
        do {
            let record = try await database.read { db in
                try ProviderAccountConfigRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM provider_account_configs WHERE account_id = ?",
                    arguments: [accountID]
                )
            }
            guard let record else { return nil }
            guard let data = record.configJSON.data(using: .utf8) else { return nil }
            return try decoder.decode(ProviderAccountConfig.self, from: data)
        } catch let error as DecodingError {
            throw ProviderAccountConfigStoreError.decodingFailed(error)
        } catch {
            throw ProviderAccountConfigStoreError.databaseError(error)
        }
    }

    public func loadAll() async throws -> [ProviderAccountConfig] {
        do {
            let records = try await database.read { db in
                try ProviderAccountConfigRecord.fetchAll(
                    db,
                    sql: "SELECT * FROM provider_account_configs ORDER BY updated_at ASC"
                )
            }
            return try records.compactMap { record in
                guard let data = record.configJSON.data(using: .utf8) else { return nil }
                return try decoder.decode(ProviderAccountConfig.self, from: data)
            }
        } catch let error as DecodingError {
            throw ProviderAccountConfigStoreError.decodingFailed(error)
        } catch {
            throw ProviderAccountConfigStoreError.databaseError(error)
        }
    }

    public func delete(accountID: String) async throws {
        do {
            try await database.write { db in
                try db.execute(
                    sql: "DELETE FROM provider_account_configs WHERE account_id = ?",
                    arguments: [accountID]
                )
            }
            logger.debug("Deleted provider config for account \(accountID)")
        } catch {
            throw ProviderAccountConfigStoreError.databaseError(error)
        }
    }
}
