import Foundation
import FileProvider
import os.log

// Wraps a non-Sendable value for capture in Task closures (FileProvider callbacks are not @Sendable).
private final class Box<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - StratusFileProviderEnumerator
// Enumerates items at a given container item for the File Provider extension.

public final class StratusFileProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {

    private let containerItem: NSFileProviderItemIdentifier
    private let provider: any CloudProvider
    private let account: CloudAccount
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "FileProviderEnumerator")

    public init(containerItem: NSFileProviderItemIdentifier, provider: any CloudProvider, account: CloudAccount) {
        self.containerItem = containerItem
        self.provider = provider
        self.account = account
    }

    // MARK: - NSFileProviderEnumerator

    public func invalidate() {}

    public func enumerateItems(for observer: any NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        // Extract Sendable values before Task to avoid region isolation errors
        let containerRaw = containerItem.rawValue
        let isRoot = containerItem == .rootContainer || containerItem == .workingSet
        let pageToken = page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
            ? nil : String(data: page.rawValue, encoding: .utf8)
        let path = isRoot ? CloudPath("/") : CloudPath(containerRaw)
        let obs = Box(observer)
        let log = logger

        Task {
            do {
                let result = try await provider.listDirectory(path: path, account: account, pageToken: pageToken)
                let parentID = NSFileProviderItemIdentifier(rawValue: containerRaw)
                let providerItems: [NSFileProviderItem] = result.items.map { item in
                    StratusFileProviderItem(item: item, parentID: parentID, accountID: account.id)
                }
                obs.value.didEnumerate(providerItems)
                if let nextToken = result.nextPageToken {
                    obs.value.finishEnumerating(upTo: NSFileProviderPage(nextToken.data(using: .utf8)!))
                } else {
                    obs.value.finishEnumerating(upTo: nil)
                }
                log.debug("Enumerated \(providerItems.count) items at \(path.path)")
            } catch {
                log.error("Enumeration failed at \(path.path): \(error)")
                obs.value.finishEnumeratingWithError(error)
            }
        }
    }

    public func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchor = NSFileProviderSyncAnchor(Data("v1".utf8))
        completionHandler(anchor)
    }
}
