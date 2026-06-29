import Foundation
import FileProvider
import os.log
import UniformTypeIdentifiers

// Wraps a non-Sendable closure so it can be captured in Task closures.
// Safe here because FileProvider serializes extension calls.
private final class CB<T>: @unchecked Sendable {
    let fn: T
    init(_ fn: T) { self.fn = fn }
}

// MARK: - StratusFileProviderExtension
// NSFileProviderReplicatedExtension (macOS 12+ modern API) for virtual filesystem.
// Each registered cloud account gets its own File Provider domain.

open class StratusFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {

    private let domain: NSFileProviderDomain
    private let resolver: StratusFileProviderDomainResolver
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "FileProviderExtension")

    // MARK: - Lifecycle

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.resolver = .shared
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
        let progress = Progress(totalUnitCount: 1)
        let cb = CB(completionHandler)
        Task {
            do {
                let context = try await resolver.resolve(domain: domain)
                if identifier == .rootContainer {
                    cb.fn(StratusFileProviderItem.root(accountID: context.account.id), nil)
                } else {
                    let path = CloudPath(identifier.rawValue)
                    let item = try await context.provider.fileMetadata(path: path, account: context.account)
                    let parentID = NSFileProviderItemIdentifier(rawValue: path.deletingLastComponent.path)
                    let providerItem = StratusFileProviderItem(item: item, parentID: parentID, accountID: context.account.id)
                    cb.fn(providerItem, nil)
                }
                progress.completedUnitCount = 1
            } catch {
                cb.fn(nil, mapFileProviderError(error))
            }
        }
        return progress
    }

    public func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                              version requestedVersion: NSFileProviderItemVersion?,
                              request: NSFileProviderRequest,
                              completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 100)
        let cb = CB(completionHandler)
        Task {
            do {
                let context = try await resolver.resolve(domain: domain)
                let path = CloudPath(itemIdentifier.rawValue)
                let downloadURL = try await context.provider.downloadURL(path: path, account: context.account, expiresIn: 3600)
                let (temporaryURL, _) = try await URLSession.shared.download(from: downloadURL)
                let cachedURL = try moveDownloadedContent(temporaryURL, itemIdentifier: itemIdentifier)
                let item = try await context.provider.fileMetadata(path: path, account: context.account)
                let parentID = NSFileProviderItemIdentifier(rawValue: path.deletingLastComponent.path)
                let providerItem = StratusFileProviderItem(item: item, parentID: parentID, accountID: context.account.id)
                progress.completedUnitCount = 100
                cb.fn(cachedURL, providerItem, nil)
            } catch {
                cb.fn(nil, nil, mapFileProviderError(error))
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
        let parentRaw = itemTemplate.parentItemIdentifier.rawValue
        let filename = itemTemplate.filename
        let isFolder = itemTemplate.contentType == .folder
        let progress = Progress(totalUnitCount: 100)
        let cb = CB(completionHandler)
        Task {
            do {
                let context = try await resolver.resolve(domain: domain)
                let parentPath = parentRaw == NSFileProviderItemIdentifier.rootContainer.rawValue ? CloudPath("/") : CloudPath(parentRaw)
                let remotePath = parentPath.appendingComponent(filename)
                let createdItem: NSFileProviderItem
                if isFolder {
                    let dir = try await context.provider.createDirectory(path: remotePath, account: context.account)
                    createdItem = StratusFileProviderItem(item: dir, parentID: NSFileProviderItemIdentifier(rawValue: parentRaw), accountID: context.account.id)
                } else if let fileURL = url {
                    let data = try Data(contentsOf: fileURL)
                    let result = try await context.provider.uploadSmallFile(data: data, remotePath: remotePath, account: context.account, metadata: UploadMetadata())
                    createdItem = StratusFileProviderItem(item: result, parentID: NSFileProviderItemIdentifier(rawValue: parentRaw), accountID: context.account.id)
                } else {
                    cb.fn(nil, [], false, NSFileProviderError(.noSuchItem))
                    return
                }
                progress.completedUnitCount = 100
                cb.fn(createdItem, [], false, nil)
            } catch {
                cb.fn(nil, [], false, mapFileProviderError(error))
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
        let itemID = item.itemIdentifier.rawValue
        let parentID = item.parentItemIdentifier.rawValue
        let newName = changedFields.contains(.filename) ? item.filename : nil
        let progress = Progress(totalUnitCount: 100)
        let cb = CB(completionHandler)
        Task {
            do {
                let context = try await resolver.resolve(domain: domain)
                let path = CloudPath(itemID)
                if let name = newName {
                    let renamed = try await context.provider.rename(path: path, newName: name, account: context.account)
                    let providerItem = StratusFileProviderItem(item: renamed, parentID: NSFileProviderItemIdentifier(rawValue: parentID), accountID: context.account.id)
                    cb.fn(providerItem, [], false, nil)
                } else if let contentsURL = newContents {
                    let data = try Data(contentsOf: contentsURL)
                    let result = try await context.provider.uploadSmallFile(data: data, remotePath: path, account: context.account, metadata: UploadMetadata())
                    let providerItem = StratusFileProviderItem(item: result, parentID: NSFileProviderItemIdentifier(rawValue: parentID), accountID: context.account.id)
                    cb.fn(providerItem, [], false, nil)
                } else {
                    cb.fn(nil, [], false, nil)
                }
                progress.completedUnitCount = 100
            } catch {
                cb.fn(nil, [], false, mapFileProviderError(error))
            }
        }
        return progress
    }

    public func deleteItem(identifier: NSFileProviderItemIdentifier,
                           baseVersion version: NSFileProviderItemVersion,
                           options: NSFileProviderDeleteItemOptions,
                           request: NSFileProviderRequest,
                           completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let cb = CB(completionHandler)
        Task {
            do {
                let context = try await resolver.resolve(domain: domain)
                let path = CloudPath(identifier.rawValue)
                try await context.provider.delete(path: path, account: context.account)
                progress.completedUnitCount = 1
                cb.fn(nil)
            } catch {
                cb.fn(mapFileProviderError(error))
            }
        }
        return progress
    }

    public func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                           request: NSFileProviderRequest) throws -> any NSFileProviderEnumerator {
        StratusFileProviderEnumerator(containerItem: containerItemIdentifier, domain: domain)
    }

    // MARK: - Domain Registration

    public static func registerDomain(for account: CloudAccount) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: FileProviderDomainStore.domainIdentifier(for: account.id)),
            displayName: FileProviderDomainStore.finderDisplayName(for: account)
        )
        try await NSFileProviderManager.add(domain)
    }

    public static func removeDomain(for accountID: String) async throws {
        let domains = try await NSFileProviderManager.domains()
        let domainID = FileProviderDomainStore.domainIdentifier(for: accountID)
        if let domain = domains.first(where: { $0.identifier.rawValue == domainID || $0.identifier.rawValue == accountID }) {
            try await NSFileProviderManager.remove(domain)
        }
    }

    // MARK: - Private

    private func moveDownloadedContent(_ url: URL, itemIdentifier: NSFileProviderItemIdentifier) throws -> URL {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StratusFileProvider", isDirectory: true)
            .appendingPathComponent(domain.identifier.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let safeName = itemIdentifier.rawValue
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let destination = cacheRoot.appendingPathComponent(safeName.isEmpty ? UUID().uuidString : safeName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    private func mapFileProviderError(_ error: any Error) -> any Error {
        if error is StratusFileProviderDomainResolverError {
            return NSFileProviderError(.notAuthenticated)
        }
        if case ProviderError.fileNotFound = error {
            return NSFileProviderError(.noSuchItem)
        }
        return error
    }
}
