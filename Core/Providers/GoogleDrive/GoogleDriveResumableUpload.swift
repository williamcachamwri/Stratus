import Foundation
import os.log

// MARK: - Google Drive Resumable Upload

// Protocol: https://developers.google.com/drive/api/guides/resumable-upload
// Chunk size MUST be multiple of 256 KB.

public actor GoogleDriveResumableUpload {
    private static let chunkSize = 8 * 1024 * 1024 // 8 MB (multiple of 256 KB)
    private static let baseURL = "https://www.googleapis.com/upload/drive/v3/files"
    private let http = HTTPClient()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "GoogleDriveUpload")

    public init() {}

    // MARK: - Initiate resumable session

    public func initiateSession(
        fileName: String,
        fileSize: Int64,
        mimeType: String,
        parentFolderID: String?,
        accessToken: String
    ) async throws -> URL {
        var body: [String: Any] = ["name": fileName]
        if let parent = parentFolderID {
            body["parents"] = [parent]
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        guard var comps = URLComponents(string: Self.baseURL) else {
            throw ProviderError.invalidResponse("Could not build resumable upload URL")
        }
        comps.queryItems = [URLQueryItem(name: "uploadType", value: "resumable")]
        guard let resumableURL = comps.url else {
            throw ProviderError.invalidResponse("Could not build resumable upload URL with query")
        }
        var request = HTTPRequest(url: resumableURL, method: .POST)
        request.headers["Authorization"] = "Bearer \(accessToken)"
        request.headers["Content-Type"] = "application/json"
        request.headers["X-Upload-Content-Type"] = mimeType
        request.headers["X-Upload-Content-Length"] = "\(fileSize)"
        request.body = bodyData

        let response = try await http.data(for: request)
        guard response.statusCode == 200,
              let locationStr = response.headers["Location"] ?? response.headers["location"],
              let sessionURI = URL(string: locationStr)
        else {
            throw GoogleDriveError.sessionInitFailed(response.statusCode)
        }
        logger.debug("Initiated resumable session: \(sessionURI.absoluteString.prefix(80))…")
        return sessionURI
    }

    // MARK: - Upload chunks sequentially (Google requires sequential)

    public func uploadFile(
        fileURL: URL,
        sessionURI: URL,
        fileSize: Int64,
        progressHandler: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> String { // Returns file ID
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset: Int64 = 0

        while offset < fileSize {
            let chunkSize = Int(min(Int64(Self.chunkSize), fileSize - offset))
            let chunk = try ChunkSlicer.readChunk(fileHandle: fileHandle, offset: offset, size: chunkSize)
            let end = offset + Int64(chunkSize) - 1

            var request = HTTPRequest(url: sessionURI, method: .PUT)
            request.headers["Content-Length"] = "\(chunkSize)"
            request.headers["Content-Range"] = "bytes \(offset)-\(end)/\(fileSize)"
            request.body = chunk

            let response = try await http.data(for: request)

            switch response.statusCode {
            case 200, 201:
                // Upload complete
                guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                      let fileID = json["id"] as? String
                else {
                    throw GoogleDriveError.missingFileID
                }
                progressHandler(fileSize, fileSize)
                return fileID

            case 308:
                // Resume Incomplete — server accepted bytes, send next chunk
                let rangeHeader = response.headers["Range"] ?? response.headers["range"]
                if let rangeStr = rangeHeader,
                   let lastByte = rangeStr.components(separatedBy: "-").last.flatMap({ Int64($0) })
                {
                    offset = lastByte + 1
                } else {
                    offset += Int64(chunkSize)
                }
                progressHandler(offset, fileSize)

            default:
                throw GoogleDriveError.uploadFailed(statusCode: response.statusCode)
            }
        }

        throw GoogleDriveError.incompleteUpload
    }

    // MARK: - Resume interrupted upload

    public func queryResumableOffset(sessionURI: URL, fileSize: Int64) async throws -> Int64 {
        var request = HTTPRequest(url: sessionURI, method: .PUT)
        request.headers["Content-Range"] = "bytes */\(fileSize)"
        request.headers["Content-Length"] = "0"

        let response = try await http.data(for: request)

        if response.statusCode == 200 || response.statusCode == 201 {
            return fileSize // already complete
        }
        if response.statusCode == 308 {
            let rangeHeader = response.headers["Range"] ?? response.headers["range"]
            if let rangeStr = rangeHeader,
               let lastByte = rangeStr.components(separatedBy: "-").last.flatMap({ Int64($0) })
            {
                return lastByte + 1
            }
            return 0 // server has nothing yet
        }
        throw GoogleDriveError.uploadFailed(statusCode: response.statusCode)
    }
}

public enum GoogleDriveError: Error, Sendable {
    case sessionInitFailed(Int)
    case uploadFailed(statusCode: Int)
    case missingFileID
    case incompleteUpload
    case rateLimited
}
