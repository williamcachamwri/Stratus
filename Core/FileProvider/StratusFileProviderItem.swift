import Foundation
import FileProvider

// MARK: - StratusFileProviderItem
// Bridges CloudFileItem into the NSFileProviderItem protocol for virtual filesystem presentation.

public final class StratusFileProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {

    // MARK: - NSFileProviderItem Required

    public let itemIdentifier: NSFileProviderItemIdentifier
    public let parentItemIdentifier: NSFileProviderItemIdentifier
    public let filename: String
    public let typeIdentifier: String
    public let capabilities: NSFileProviderItemCapabilities

    // MARK: - NSFileProviderItem Optional

    public let documentSize: NSNumber?
    public let contentModificationDate: Date?
    public let creationDate: Date?
    public let childItemCount: NSNumber?
    public let isTrashed: Bool
    public let isDownloaded: Bool
    public let isDownloading: Bool
    public let isUploaded: Bool
    public let isUploading: Bool
    public let uploadingError: Error?
    public let downloadingError: Error?
    public let versionIdentifier: Data?

    // MARK: - Custom

    let cloudItem: CloudFileItem
    let accountID: String

    // MARK: - Init from CloudFileItem

    public init(item: CloudFileItem, parentID: NSFileProviderItemIdentifier, accountID: String) {
        self.cloudItem = item
        self.accountID = accountID
        self.itemIdentifier = NSFileProviderItemIdentifier(item.id)
        self.parentItemIdentifier = parentID
        self.filename = item.name
        self.typeIdentifier = item.isDirectory
            ? "public.folder"
            : UTType(filenameExtension: (item.name as NSString).pathExtension)?.identifier ?? "public.data"
        self.documentSize = item.size.map { NSNumber(value: $0) }
        self.contentModificationDate = item.modifiedAt
        self.creationDate = item.createdAt
        self.childItemCount = item.isDirectory ? NSNumber(value: 0) : nil
        self.isTrashed = false
        self.isDownloaded = true
        self.isDownloading = false
        self.isUploaded = true
        self.isUploading = false
        self.uploadingError = nil
        self.downloadingError = nil
        self.versionIdentifier = item.etag.flatMap { $0.data(using: .utf8) }

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

// MARK: - UTType helper

import UniformTypeIdentifiers

private extension UTType {
    init?(filenameExtension ext: String) {
        guard !ext.isEmpty else { return nil }
        self.init(tag: ext, tagClass: .filenameExtension, conformingTo: nil)
    }
}
