import Foundation

// MARK: - Google Drive File Metadata
// Codable models for the Google Drive Files API v3 responses.

public struct GoogleDriveFile: Codable, Sendable {

    // MARK: - MIME type constant

    /// The MIME type Google Drive assigns to folder items.
    public static let folderMimeType = "application/vnd.google-apps.folder"

    // MARK: - Properties

    public let id: String
    public let name: String
    public let mimeType: String
    /// File size in bytes as a string (Google Drive returns numeric strings).
    public let size: String?
    /// RFC 3339 modification timestamp, e.g. `"2024-01-15T12:00:00.000Z"`.
    public let modifiedTime: String?
    /// Parent folder IDs.
    public let parents: [String]?

    // MARK: - Derived helpers

    public var isFolder: Bool { mimeType == Self.folderMimeType }

    /// Size in bytes, parsed from the `size` string field.
    public var sizeBytes: Int64? { size.flatMap(Int64.init) }

    /// `modifiedTime` parsed into a `Date`.  Returns `nil` if the string is
    /// absent or does not conform to ISO 8601.
    public var modificationDate: Date? {
        guard let raw = modifiedTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
            ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - CloudFileItem conversion

    /// Converts this `GoogleDriveFile` into a `CloudFileItem`.
    /// - Parameter parentPath: The `CloudPath` of the containing folder.
    public func toCloudFileItem(parentPath: CloudPath) -> CloudFileItem {
        CloudFileItem(
            id: id,
            name: name,
            path: parentPath.appendingComponent(name),
            size: sizeBytes,
            contentType: isFolder ? nil : mimeType,
            modificationDate: modificationDate,
            isDirectory: isFolder
        )
    }
}

// MARK: - GoogleDriveFileList

public struct GoogleDriveFileList: Codable, Sendable {
    public let files: [GoogleDriveFile]
    public let nextPageToken: String?

    public init(files: [GoogleDriveFile], nextPageToken: String? = nil) {
        self.files = files
        self.nextPageToken = nextPageToken
    }
}
