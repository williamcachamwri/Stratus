import Foundation

// MARK: - FileProviderDomainStatus

public enum FileProviderDomainStatus: String, Codable, Sendable {
    case mounted
    case unmounted
    case error
}

// MARK: - FileProviderDomainRecord

public struct FileProviderDomainRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let accountID: String
    public let providerID: String
    public let accountDisplayName: String
    public let finderDisplayName: String
    public var status: FileProviderDomainStatus
    public var statusMessage: String?
    public var mountedAt: Date?
    public var updatedAt: Date

    public init(
        id: String,
        accountID: String,
        providerID: String,
        accountDisplayName: String,
        finderDisplayName: String,
        status: FileProviderDomainStatus,
        statusMessage: String? = nil,
        mountedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.providerID = providerID
        self.accountDisplayName = accountDisplayName
        self.finderDisplayName = finderDisplayName
        self.status = status
        self.statusMessage = statusMessage
        self.mountedAt = mountedAt
        self.updatedAt = updatedAt
    }
}

// MARK: - FileProviderDomainStoreError

public enum FileProviderDomainStoreError: Error, Sendable {
    case encodingFailed(any Error)
    case decodingFailed(any Error)
    case persistenceFailed(any Error)
}

// MARK: - FileProviderDomainStore

/// Small JSON store shared by the app and the File Provider extension.
///
/// File Provider extensions run in a different process, so they cannot depend on
/// providers/accounts injected in the main app's memory. This store is the stable
/// bridge from `NSFileProviderDomain.identifier` back to the persisted account.
public actor FileProviderDomainStore {
    public static let shared = FileProviderDomainStore()

    public static let appGroupIdentifier = "group.com.stratus.cloudmanager"
    public static let domainPrefix = "stratus.account."

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let fileURL: URL

    public init(fileURL: URL? = nil) {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        self.fileURL = fileURL ?? Self.defaultStoreURL()
    }

    public nonisolated static func domainIdentifier(for accountID: String) -> String {
        if accountID.hasPrefix(domainPrefix) { return accountID }
        return domainPrefix + accountID
    }

    public nonisolated static func accountID(from domainIdentifier: String) -> String {
        if domainIdentifier.hasPrefix(domainPrefix) {
            return String(domainIdentifier.dropFirst(domainPrefix.count))
        }
        return domainIdentifier
    }

    public nonisolated static func finderDisplayName(for account: CloudAccount) -> String {
        "Stratus - \(account.displayName)"
    }

    public func save(_ record: FileProviderDomainRecord) throws {
        do {
            var records = try loadAll()
            records.removeAll { $0.id == record.id || $0.accountID == record.accountID }
            records.append(record)
            try persist(records.sorted { $0.finderDisplayName.localizedCaseInsensitiveCompare($1.finderDisplayName) == .orderedAscending })
        } catch let error as FileProviderDomainStoreError {
            throw error
        } catch {
            throw FileProviderDomainStoreError.persistenceFailed(error)
        }
    }

    public func markError(account: CloudAccount, message: String) throws {
        let now = Date()
        let record = FileProviderDomainRecord(
            id: Self.domainIdentifier(for: account.id),
            accountID: account.id,
            providerID: account.providerID,
            accountDisplayName: account.displayName,
            finderDisplayName: Self.finderDisplayName(for: account),
            status: .error,
            statusMessage: message,
            mountedAt: nil,
            updatedAt: now
        )
        try save(record)
    }

    public func remove(accountID: String) throws {
        var records = try loadAll()
        records.removeAll { $0.accountID == accountID || $0.id == accountID || $0.id == Self.domainIdentifier(for: accountID) }
        try persist(records)
    }

    public func load(domainIdentifier: String) throws -> FileProviderDomainRecord? {
        let normalizedAccountID = Self.accountID(from: domainIdentifier)
        return try loadAll().first { $0.id == domainIdentifier || $0.accountID == normalizedAccountID }
    }

    public func loadAll() throws -> [FileProviderDomainRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([FileProviderDomainRecord].self, from: data)
        } catch let error as DecodingError {
            throw FileProviderDomainStoreError.decodingFailed(error)
        } catch {
            throw FileProviderDomainStoreError.persistenceFailed(error)
        }
    }

    private func persist(_ records: [FileProviderDomainRecord]) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch let error as EncodingError {
            throw FileProviderDomainStoreError.encodingFailed(error)
        } catch {
            throw FileProviderDomainStoreError.persistenceFailed(error)
        }
    }

    private nonisolated static func defaultStoreURL() -> URL {
        let fm = FileManager.default
        if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return groupURL
                .appendingPathComponent("FileProvider", isDirectory: true)
                .appendingPathComponent("domains.json")
        }
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return appSupport
            .appendingPathComponent("Stratus", isDirectory: true)
            .appendingPathComponent("FileProvider", isDirectory: true)
            .appendingPathComponent("domains.json")
    }
}
