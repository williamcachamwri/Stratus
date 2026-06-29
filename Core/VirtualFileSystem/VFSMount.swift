import Foundation
import FileProvider
import os.log

// MARK: - VFSMountError

public enum VFSMountError: Error, Sendable {
    case alreadyMounted(accountID: String)
    case notMounted(accountID: String)
    case domainRegistrationFailed(accountID: String, underlying: any Error)
    case domainRemovalFailed(accountID: String, underlying: any Error)
    case managerUnavailable(accountID: String)
}

extension VFSMountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyMounted:
            return "This account is already mounted in Finder."
        case .notMounted:
            return "This account is not currently mounted."
        case .domainRegistrationFailed(_, let underlying):
            return "Finder mount failed: \(underlying.localizedDescription)"
        case .domainRemovalFailed(_, let underlying):
            return "Finder unmount failed: \(underlying.localizedDescription)"
        case .managerUnavailable(let id):
            return "File Provider manager unavailable for account \(id)."
        }
    }
}

// MARK: - VFSMountSnapshot

public struct VFSMountSnapshot: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let providerID: String
    public let accountDisplayName: String
    public let finderDisplayName: String
    public let status: FileProviderDomainStatus
    public let statusMessage: String?
    public let mountedAt: Date?

    public init(record: FileProviderDomainRecord) {
        id = record.id
        accountID = record.accountID
        providerID = record.providerID
        accountDisplayName = record.accountDisplayName
        finderDisplayName = record.finderDisplayName
        status = record.status
        statusMessage = record.statusMessage
        mountedAt = record.mountedAt
    }
}

// MARK: - VFSMount

/// Manages FileProvider-based cloud volume mounting.
///
/// Each `CloudAccount` is mapped to one `NSFileProviderDomain`; registering that
/// domain is what makes Finder show a Stratus volume under Locations.
public actor VFSMount {
    public static let shared = VFSMount()

    // MARK: - State

    private var domains: [String: NSFileProviderDomain] = [:]
    private var mountedAccountsByID: [String: CloudAccount] = [:]
    private let domainStore: FileProviderDomainStore
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "VFSMount")

    // MARK: - Init

    public init(domainStore: FileProviderDomainStore = .shared) {
        self.domainStore = domainStore
    }

    // MARK: - Public Interface

    public var mountedAccounts: [CloudAccount] {
        get async { Array(mountedAccountsByID.values) }
    }

    public func snapshots() async -> [VFSMountSnapshot] {
        do {
            return try await domainStore.loadAll().map(VFSMountSnapshot.init(record:))
        } catch {
            logger.error("Failed to load mount snapshots: \(error.localizedDescription)")
            return []
        }
    }

    /// Rehydrates domain state from Finder's registered domains and our shared
    /// store. Call this at app launch before rendering Mount Manager.
    public func reloadMountedDomains(accounts: [CloudAccount]) async {
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        do {
            let registered = try await NSFileProviderManager.domains()
            domains.removeAll()
            mountedAccountsByID.removeAll()

            for domain in registered {
                let rawID = domain.identifier.rawValue
                guard rawID.hasPrefix(FileProviderDomainStore.domainPrefix) else { continue }
                let accountID = FileProviderDomainStore.accountID(from: rawID)
                domains[accountID] = domain
                if let account = byID[accountID] {
                    mountedAccountsByID[accountID] = account
                    try await persistMountedRecord(for: account)
                }
            }
        } catch {
            logger.error("Failed to reload Finder domains: \(error.localizedDescription)")
        }
    }

    // MARK: - Mount

    public func mount(account: CloudAccount) async throws {
        let domainID = FileProviderDomainStore.domainIdentifier(for: account.id)
        guard domains[account.id] == nil else {
            throw VFSMountError.alreadyMounted(accountID: account.id)
        }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: domainID),
            displayName: FileProviderDomainStore.finderDisplayName(for: account)
        )

        do {
            try await NSFileProviderManager.add(domain)
            domains[account.id] = domain
            mountedAccountsByID[account.id] = account
            try await persistMountedRecord(for: account)
            logger.info("Mounted Finder volume \(domain.displayName, privacy: .public) for account \(account.id, privacy: .public)")
        } catch {
            try? await domainStore.markError(account: account, message: error.localizedDescription)
            logger.error("Failed to add domain for account \(account.id, privacy: .public): \(error.localizedDescription)")
            throw VFSMountError.domainRegistrationFailed(accountID: account.id, underlying: error)
        }
    }

    // MARK: - Unmount

    public func unmount(account: CloudAccount) async throws {
        let domain = domains[account.id] ?? NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: FileProviderDomainStore.domainIdentifier(for: account.id)),
            displayName: FileProviderDomainStore.finderDisplayName(for: account)
        )

        do {
            try await NSFileProviderManager.remove(domain)
            domains.removeValue(forKey: account.id)
            mountedAccountsByID.removeValue(forKey: account.id)
            try await domainStore.remove(accountID: account.id)
            logger.info("Unmounted Finder volume for account \(account.id, privacy: .public)")
        } catch {
            try? await domainStore.markError(account: account, message: error.localizedDescription)
            logger.error("Failed to remove domain for account \(account.id, privacy: .public): \(error.localizedDescription)")
            throw VFSMountError.domainRemovalFailed(accountID: account.id, underlying: error)
        }
    }

    // MARK: - Signal changes

    public func signalEnumeratorForWorkingSet(account: CloudAccount) async throws {
        let domain = try domain(for: account)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw VFSMountError.managerUnavailable(accountID: account.id)
        }
        try await manager.signalEnumerator(for: .workingSet)
        logger.debug("Signalled working set enumerator for account \(account.id, privacy: .public)")
    }

    public func signalEnumerator(for itemIdentifier: NSFileProviderItemIdentifier,
                                 account: CloudAccount) async throws {
        let domain = try domain(for: account)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw VFSMountError.managerUnavailable(accountID: account.id)
        }
        try await manager.signalEnumerator(for: itemIdentifier)
    }

    // MARK: - Private

    private func persistMountedRecord(for account: CloudAccount) async throws {
        let record = FileProviderDomainRecord(
            id: FileProviderDomainStore.domainIdentifier(for: account.id),
            accountID: account.id,
            providerID: account.providerID,
            accountDisplayName: account.displayName,
            finderDisplayName: FileProviderDomainStore.finderDisplayName(for: account),
            status: .mounted,
            statusMessage: nil,
            mountedAt: Date(),
            updatedAt: Date()
        )
        try await domainStore.save(record)
    }

    private func domain(for account: CloudAccount) throws -> NSFileProviderDomain {
        if let domain = domains[account.id] { return domain }
        throw VFSMountError.notMounted(accountID: account.id)
    }
}
