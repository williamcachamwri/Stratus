import FileProvider
import Foundation

// MARK: - StratusFileProviderDomainContext

public struct StratusFileProviderDomainContext: Sendable {
    public let account: CloudAccount
    public let provider: any CloudProvider
    public let record: FileProviderDomainRecord?
}

// MARK: - StratusFileProviderDomainResolver

public enum StratusFileProviderDomainResolverError: Error, Sendable {
    case accountMissing(domainIdentifier: String)
    case providerMissing(accountID: String, providerID: String)
}

/// Resolves an `NSFileProviderDomain` into real account/provider runtime state.
///
/// This is intentionally disk-backed because the File Provider extension runs in
/// a separate process from the main app.
public actor StratusFileProviderDomainResolver {
    public static let shared = StratusFileProviderDomainResolver()

    private let domainStore: FileProviderDomainStore
    private let accountStore: AccountStore
    private let configStore: ProviderAccountConfigStore

    public init(
        domainStore: FileProviderDomainStore = .shared,
        accountStore: AccountStore = .shared,
        configStore: ProviderAccountConfigStore = .shared
    ) {
        self.domainStore = domainStore
        self.accountStore = accountStore
        self.configStore = configStore
    }

    public func resolve(domain: NSFileProviderDomain) async throws -> StratusFileProviderDomainContext {
        try await resolve(domainIdentifier: domain.identifier.rawValue)
    }

    public func resolve(domainIdentifier: String) async throws -> StratusFileProviderDomainContext {
        let record = try await domainStore.load(domainIdentifier: domainIdentifier)
        let accountID = record?.accountID ?? FileProviderDomainStore.accountID(from: domainIdentifier)
        guard let account = try await accountStore.load(id: accountID) else {
            throw StratusFileProviderDomainResolverError.accountMissing(domainIdentifier: domainIdentifier)
        }
        let config = try await configStore.load(accountID: account.id)
        guard let provider = await CloudProviderFactory.makeProvider(for: account, config: config) else {
            throw StratusFileProviderDomainResolverError.providerMissing(
                accountID: account.id,
                providerID: account.providerID
            )
        }
        return StratusFileProviderDomainContext(account: account, provider: provider, record: record)
    }
}
