import Foundation
import FileProvider
import UniformTypeIdentifiers

// MARK: - StratusFileProviderItem
// Bridges CloudFileItem into the NSFileProviderItem protocol for virtual filesystem presentation.

public final class StratusFileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {

    // MARK: - NSFileProviderItem Required (macOS modern API)

    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let contentType: UTType
    public let capabilities: NSFileProviderItemCapabilities

    // MARK: - NSFileProviderItem Optional

    public let documentSize: NSNumber?
    public let contentModificationDate: Date?
    public let creationDate: Date?
    public let childItemCount: NSNumber?
    public let isDownloaded: Bool
    public let isDownloading: Bool
    public let isUploaded: Bool
    public let isUploading: Bool
    public let uploadingError: Error?
    public let downloadingError: Error?
    public let itemVersion: NSFileProviderItemVersion

    // MARK: - Custom

    public let cloudItem: CloudFileItem
    public let accountID: String

    // MARK: - Init from CloudFileItem

    public init(item: CloudFileItem, parentID: NSFileProviderItemIdentifier, accountID: String) {
        self.cloudItem = item
        self.accountID = accountID
        self.itemIdentifier = NSFileProviderItemIdentifier(item.id)
        self.parentItemIdentifier = parentID
        self.filename = item.name

        if item.isDirectory {
            self.contentType = .folder
        } else {
            let ext = (item.name as NSString).pathExtension
            self.contentType = UTType(filenameExtension: ext) ?? .data
        }

        self.documentSize = item.size.map { NSNumber(value: $0) }
        self.contentModificationDate = item.modificationDate
        self.creationDate = item.creationDate
        self.childItemCount = item.isDirectory ? NSNumber(value: 0) : nil
        self.isDownloaded = true
        self.isDownloading = false
        self.isUploaded = true
        self.isUploading = false
        self.uploadingError = nil
        self.downloadingError = nil

        let versionData = item.etag?.data(using: .utf8) ?? Data()
        self.itemVersion = NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)

        if item.isDirectory {
            self.capabilities = [.allowsAddingSubItems, .allowsContentEnumerating,
                                  .allowsReading, .allowsDeleting, .allowsRenaming]
        } else {
            self.capabilities = [.allowsReading, .allowsWriting, .allowsDeleting,
                                  .allowsRenaming, .allowsReparenting]
        }
    }

    // MARK: - Root item

    public static func root(accountID: String) -> StratusFileProviderItem {
        let rootItem = CloudFileItem(id: NSFileProviderItemIdentifier.rootContainer.rawValue,
                                     name: "Stratus", path: CloudPath("/"), isDirectory: true)
        return StratusFileProviderItem(item: rootItem, parentID: .rootContainer, accountID: accountID)
    }
}
