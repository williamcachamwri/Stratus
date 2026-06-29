import Foundation
import FileProvider
import os.log

// Wraps a non-Sendable closure so it can be captured in Task closures.
// Safe here because FileProvider serializes extension calls.
private final class CB<T>: @unchecked Sendable {
    let fn: T
    init(_ fn: T) { self.fn = fn }
}

// MARK: - StratusFileProviderExtension
// NSFileProviderReplicatedExtension (macOS 12+ modern API) for virtual filesystem.
// Each registered cloud account gets its own File Provider domain.

public final class StratusFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private nonisolated(unsafe) var provider: (any CloudProvider)?
    private nonisolated(unsafe) var account: CloudAccount?
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "FileProviderExtension")

    // MARK: - Lifecycle

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
        logger.info("FileProvider extension initialized for domain: \(domain.identifier.rawValue)")
    }

    public func invalidate() {
        logger.info("FileProvider extension invalidated for domain: \(self.domain.identifier.rawValue)")
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
        let cb = CB(completionHandler)
        Task {
            do {
                if identifier == .rootContainer {
                    cb.fn(StratusFileProviderItem.root(accountID: account.id), nil)
                } else {
                    let path = CloudPath(identifier.rawValue)
                    let item = try await provider.fileMetadata(path: path, account: account)
                    let providerItem = StratusFileProviderItem(item: item, parentID: .rootContainer, accountID: account.id)
                    cb.fn(providerItem, nil)
                }
                progress.completedUnitCount = 1
            } catch {
                cb.fn(nil, error)
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
        let cb = CB(completionHandler)
        Task {
            do {
                let path = CloudPath(itemIdentifier.rawValue)
                let downloadURL = try await provider.downloadURL(path: path, account: account, expiresIn: 3600)
                let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
                let item = try await provider.fileMetadata(path: path, account: account)
                let providerItem = StratusFileProviderItem(item: item, parentID: .rootContainer, accountID: account.id)
                progress.completedUnitCount = 100
                cb.fn(tempURL, providerItem, nil)
            } catch {
                cb.fn(nil, nil, error)
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
        // Extract Sendable values from ObjC NSFileProviderItem before Task
        let parentRaw = itemTemplate.parentItemIdentifier.rawValue
        let filename = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let progress = Progress(totalUnitCount: 100)
        let cb = CB(completionHandler)
        Task {
            do {
                let remotePath = CloudPath(parentRaw).appendingComponent(filename)
                let createdItem: NSFileProviderItem
                if isFolder {
                    let dir = try await provider.createDirectory(path: remotePath, account: account)
                    createdItem = StratusFileProviderItem(item: dir, parentID: NSFileProviderItemIdentifier(rawValue: parentRaw), accountID: account.id)
                } else if let fileURL = url {
                    let data = try Data(contentsOf: fileURL)
                    let result = try await provider.uploadSmallFile(data: data, remotePath: remotePath, account: account, metadata: UploadMetadata())
                    createdItem = StratusFileProviderItem(item: result, parentID: NSFileProviderItemIdentifier(rawValue: parentRaw), accountID: account.id)
                } else {
                    cb.fn(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }
                progress.completedUnitCount = 100
                cb.fn(createdItem, [], false, nil)
            } catch {
                cb.fn(nil, [], false, error)
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
        // Extract Sendable values from ObjC item before Task
        let itemID = item.itemIdentifier.rawValue
        let parentID = item.parentItemIdentifier.rawValue
        let newName = changedFields.contains(.filename) ? (item.filename as String?) : nil
        let progress = Progress(totalUnitCount: 100)
        let cb = CB(completionHandler)
        Task {
            do {
                let path = CloudPath(itemID)
                if let name = newName {
                    let renamed = try await provider.rename(path: path, newName: name, account: account)
                    let providerItem = StratusFileProviderItem(item: renamed, parentID: NSFileProviderItemIdentifier(rawValue: parentID), accountID: account.id)
                    cb.fn(providerItem, [], false, nil)
                } else if let contentsURL = newContents {
                    let data = try Data(contentsOf: contentsURL)
                    let result = try await provider.uploadSmallFile(data: data, remotePath: path, account: account, metadata: UploadMetadata())
                    let providerItem = StratusFileProviderItem(item: result, parentID: NSFileProviderItemIdentifier(rawValue: parentID), accountID: account.id)
                    cb.fn(providerItem, [], false, nil)
                } else {
                    cb.fn(nil, [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                cb.fn(nil, [], false, error)
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
        let cb = CB(completionHandler)
        Task {
            do {
                let path = CloudPath(identifier.rawValue)
                try await provider.delete(path: path, account: account)
                progress.completedUnitCount = 1
                cb.fn(nil)
            } catch {
                cb.fn(error)
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
