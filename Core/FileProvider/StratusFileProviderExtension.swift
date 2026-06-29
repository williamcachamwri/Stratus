import Foundation
import FileProvider
import os.log

// MARK: - StratusFileProviderExtension
// NSFileProviderReplicatedExtension (macOS 12+ modern API) for virtual filesystem.
// Each registered cloud account gets its own File Provider domain.

public final class StratusFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private var provider: (any CloudProvider)?
    private var account: CloudAccount?
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "FileProviderExtension")

    // MARK: - Lifecycle

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("FileProvider extension initialized for domain: \(domain.identifier.rawValue)")
    }

    public func invalidate() {
        logger.info("FileProvider extension invalidated for domain: \(domain.identifier.rawValue)")
    }

    // MARK: - NSFileProviderReplicatedExtension

    public func item(for identifier: NSFileProviderItemIdentifier,
                     request: NSFileProviderRequest,
                     completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let provider, let account else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                if identifier == .rootContainer {
                    completionHandler(StratusFileProviderItem.root(accountID: account.id), nil)
                } else {
                    let path = CloudPath(identifier.rawValue)
                    let item = try await provider.fileMetadata(path: path, account: account)
                    let providerItem = StratusFileProviderItem(item: item, parentID: .rootContainer, accountID: account.id)
                    completionHandler(providerItem, nil)
                }
                progress.completedUnitCount = 1
            } catch {
                completionHandler(nil, error)
            }
        }
        return progress
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                               version requestedVersion: NSFileProviderItemVersion?,
                               request: NSFileProviderRequest,
                               completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        guard let provider, let account else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let path = CloudPath(itemIdentifier.rawValue)
                let downloadURL = try await provider.downloadURL(path: path, account: account, expiresIn: 3600)
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let item = try await provider.fileMetadata(path: path, account: account)
                let providerItem = StratusFileProviderItem(item: item, parentID: .rootContainer, accountID: account.id)
                progress.completedUnitCount = 100
                completionHandler(tempURL, providerItem, nil)
            } catch {
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    public func createItem(basedOn itemTemplate: NSFileProviderItem,
                            fields: NSFileProviderItemFields,
                            contents url: URL?,
                            options: NSFileProviderCreateItemOptions,
                            request: NSFileProviderRequest,
                            completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let provider, let account else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let remotePath = CloudPath(itemTemplate.parentItemIdentifier.rawValue)
                    .appendingComponent(itemTemplate.filename)
                let createdItem: NSFileProviderItem
                if itemTemplate.contentType == .folder {
                    let dir = try await provider.createDirectory(path: remotePath, account: account)
                    createdItem = StratusFileProviderItem(item: dir, parentID: itemTemplate.parentItemIdentifier, accountID: account.id)
                } else if let fileURL = url {
                    let data = try Data(contentsOf: fileURL)
                    let result = try await provider.uploadSmallFile(data: data, remotePath: remotePath, account: account, metadata: UploadMetadata(fileName: itemTemplate.filename, fileSize: Int64(data.count)))
                    createdItem = StratusFileProviderItem(item: result, parentID: itemTemplate.parentItemIdentifier, accountID: account.id)
                } else {
                    completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }
                progress.completedUnitCount = 100
                completionHandler(createdItem, [], false, nil)
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    public func modifyItem(_ item: NSFileProviderItem,
                            baseVersion version: NSFileProviderItemVersion,
                            changedFields: NSFileProviderItemFields,
                            contents newContents: URL?,
                            options: NSFileProviderModifyItemOptions,
                            request: NSFileProviderRequest,
                            completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        guard let provider, let account else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 100)
        Task {
            do {
                let path = CloudPath(item.itemIdentifier.rawValue)
                if changedFields.contains(.filename), let newName = item.filename as String? {
                    let renamed = try await provider.rename(path: path, newName: newName, account: account)
                    let providerItem = StratusFileProviderItem(item: renamed, parentID: item.parentItemIdentifier, accountID: account.id)
                    completionHandler(providerItem, [], false, nil)
                } else if let contentsURL = newContents {
                    let data = try Data(contentsOf: contentsURL)
                    let result = try await provider.uploadSmallFile(data: data, remotePath: path, account: account, metadata: UploadMetadata(fileName: item.filename, fileSize: Int64(data.count)))
                    let providerItem = StratusFileProviderItem(item: result, parentID: item.parentItemIdentifier, accountID: account.id)
                    completionHandler(providerItem, [], false, nil)
                } else {
                    completionHandler(item, [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                completionHandler(nil, [], false, error)
            }
        }
        return progress
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier,
                            baseVersion version: NSFileProviderItemVersion,
                            options: NSFileProviderDeleteItemOptions,
                            request: NSFileProviderRequest,
                            completionHandler: @escaping (Error?) -> Void) -> Progress {
        guard let provider, let account else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return Progress()
        }
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                let path = CloudPath(identifier.rawValue)
                try await provider.delete(path: path, account: account)
                progress.completedUnitCount = 1
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
        return progress
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                            request: NSFileProviderRequest) throws -> any NSFileProviderEnumerator {
        guard let provider, let account else {
            throw NSFileProviderError(.noSuchItem)
        }
        return StratusFileProviderEnumerator(containerItem: containerItemIdentifier,
                                              provider: provider,
                                              account: account)
    }

    // MARK: - Domain Registration

    public static func registerDomain(for account: CloudAccount) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: account.id),
            displayName: account.displayName
        )
        try await NSFileProviderManager.add(domain)
    }

    public static func removeDomain(for accountID: String) async throws {
        let domains = try await NSFileProviderManager.domains()
        if let domain = domains.first(where: { $0.identifier.rawValue == accountID }) {
            try await NSFileProviderManager.remove(domain)
        }
    }

    public func configure(provider: any CloudProvider, account: CloudAccount) {
        self.provider = provider
        self.account = account
    }
}
