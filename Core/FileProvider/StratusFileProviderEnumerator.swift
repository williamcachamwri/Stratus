import Foundation
import FileProvider
import os.log

// MARK: - StratusFileProviderEnumerator
// Enumerates items at a given container item for the File Provider extension.

public final class StratusFileProviderEnumerator: NSObject, NSFileProviderEnumerator {

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
        let path: CloudPath
        if containerItem == .rootContainer || containerItem == .workingSet {
            path = CloudPath("/")
        } else {
            path = CloudPath(containerItem.rawValue)
        }

        Task {
            do {
                let pageToken = page == NSFileProviderPage.initialPageSortedByName as NSFileProviderPage
                    ? nil
                    : String(data: page.rawValue, encoding: .utf8)

                let result = try await provider.listDirectory(path: path, account: account, pageToken: pageToken)

                let providerItems: [NSFileProviderItem] = result.items.map { item in
                    StratusFileProviderItem(item: item, parentID: containerItem, accountID: account.id)
                }

                observer.didEnumerate(providerItems)

                if let nextToken = result.nextPageToken {
                    let nextPage = NSFileProviderPage(nextToken.data(using: .utf8)!)
                    observer.finishEnumerating(upTo: nextPage)
                } else {
                    observer.finishEnumerating(upTo: nil)
                }
                logger.debug("Enumerated \(providerItems.count) items at \(path.path)")
            } catch {
                logger.error("Enumeration failed at \(path.path): \(error)")
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    public func enumerateChanges(for observer: any NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        // Report no changes — real implementation would diff against stored state
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    public func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchor = NSFileProviderSyncAnchor(Data("v1".utf8))
        completionHandler(anchor)
    }
}
