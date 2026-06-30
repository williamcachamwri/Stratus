import Foundation

public enum GoogleDriveWebLink {
    private static let editorPaths = [
        "application/vnd.google-apps.document": "document",
        "application/vnd.google-apps.spreadsheet": "spreadsheets",
        "application/vnd.google-apps.presentation": "presentation",
        "application/vnd.google-apps.form": "forms",
        "application/vnd.google-apps.drawing": "drawings",
    ]

    public static func url(fileID: String, mimeType: String?) -> URL? {
        let trimmedID = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return nil }

        if mimeType == GoogleDriveFile.folderMimeType {
            return URL(string: "https://drive.google.com/drive/folders/\(trimmedID)")
        }

        if let mimeType, let editorPath = editorPaths[mimeType] {
            return URL(string: "https://docs.google.com/\(editorPath)/d/\(trimmedID)/edit")
        }

        return URL(string: "https://drive.google.com/file/d/\(trimmedID)/view")
    }

    public static func actionTitle(mimeType: String?) -> String {
        switch mimeType {
        case "application/vnd.google-apps.document":
            "Open in Google Docs"
        case "application/vnd.google-apps.spreadsheet":
            "Open in Google Sheets"
        case "application/vnd.google-apps.presentation":
            "Open in Google Slides"
        case "application/vnd.google-apps.form":
            "Open in Google Forms"
        case "application/vnd.google-apps.drawing":
            "Open in Google Drawings"
        default:
            "Open in Google Drive"
        }
    }
}
