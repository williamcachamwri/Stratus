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

// MARK: - VFSMount

/// Manages FileProvider-based cloud volume mounting.
/// Each `CloudAccount` is mapped to a unique `NSFileProviderDomain`; mounting
/// adds the domain to `NSFileProviderManager` so macOS exposes it as a volume
/// in Finder.  Unmounting removes the domain and tears down the manager.
public actor VFSMount {

    // MARK: - State

    private var domains: [String: NSFileProviderDomain] = [:]
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "VFSMount")

    // MARK: - Init

    public init() {}

    // MARK: - Public Interface

    /// All accounts whose FileProvider domains are currently active.
    public var mountedAccounts: [CloudAccount] {
        get async { Array(mountedAccountsByID.values) }
    }

    // MARK: - Mount

    /// Registers a `NSFileProviderDomain` for `account` so macOS treats it as
    /// a virtual volume.  Throws `VFSMountError.alreadyMounted` if the account
    /// is already mounted to prevent duplicate domains.
    public func mount(account: CloudAccount) async throws {
        guard domains[account.id] == nil else {
            throw VFSMountError.alreadyMounted(accountID: account.id)
        }

        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: account.id),
            displayName: account.displayName
        )

        do {
            try await NSFileProviderManager.add(domain)
        } catch {
            logger.error("Failed to add domain for account \(account.id, privacy: .public): \(error)")
            throw VFSMountError.domainRegistrationFailed(accountID: account.id, underlying: error)
        }

        domains[account.id] = domain
        mountedAccountsByID[account.id] = account
        logger.info("Mounted volume for account \(account.displayName, privacy: .public) (\(account.id, privacy: .public))")
    }

    // MARK: - Unmount

    /// Removes the `NSFileProviderDomain` associated with `account`, signalling
    /// macOS to eject the virtual volume.  Throws `VFSMountError.notMounted` if
    /// no domain exists for the given account.
    public func unmount(account: CloudAccount) async throws {
        guard let domain = domains[account.id] else {
            throw VFSMountError.notMounted(accountID: account.id)
        }

        do {
            try await NSFileProviderManager.remove(domain)
        } catch {
            logger.error("Failed to remove domain for account \(account.id, privacy: .public): \(error)")
            throw VFSMountError.domainRemovalFailed(accountID: account.id, underlying: error)
        }

        domains.removeValue(forKey: account.id)
        mountedAccountsByID.removeValue(forKey: account.id)
        logger.info("Unmounted volume for account \(account.displayName, privacy: .public) (\(account.id, privacy: .public))")
    }

    // MARK: - Signal changes

    /// Signals the FileProvider framework that the working set has changed for
    /// `account`, causing macOS to re-enumerate the root of that domain.
    public func signalEnumeratorForWorkingSet(account: CloudAccount) async throws {
        guard let domain = domains[account.id] else {
            throw VFSMountError.notMounted(accountID: account.id)
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw VFSMountError.managerUnavailable(accountID: account.id)
        }
        try await manager.signalEnumerator(for: .workingSet)
        logger.debug("Signalled working set enumerator for account \(account.id, privacy: .public)")
    }

    /// Signals the FileProvider framework that a specific item has changed.
    public func signalEnumerator(for itemIdentifier: NSFileProviderItemIdentifier,
                                 account: CloudAccount) async throws {
        guard let domain = domains[account.id] else {
            throw VFSMountError.notMounted(accountID: account.id)
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw VFSMountError.managerUnavailable(accountID: account.id)
        }
        try await manager.signalEnumerator(for: itemIdentifier)
    }

    // MARK: - Private

    // Secondary store keyed by accountID; mirrors `domains` for O(1) account lookup.
    private var mountedAccountsByID: [String: CloudAccount] = [:]
}
