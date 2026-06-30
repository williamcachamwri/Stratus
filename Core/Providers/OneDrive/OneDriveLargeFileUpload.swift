import Foundation
import os.log

// MARK: - OneDriveLargeFileUpload

// Implements the Microsoft Graph large-file upload session protocol.
//
// Flow:
//   1. POST to createUploadSession    → receive uploadUrl
//   2. PUT byte-range chunks          → server responds 202 (incomplete) or 201/200 (complete)
//   3. Repeat step 2 until complete
//
// Reference: https://learn.microsoft.com/graph/api/driveitem-createuploadsession

public enum OneDriveLargeFileUploadError: Error, Sendable {
    case sessionCreationFailed(statusCode: Int, body: String)
    case chunkUploadFailed(statusCode: Int, body: String)
    case invalidUploadURL(String)
    case missingUploadURL
}

public actor OneDriveLargeFileUpload {
    // MARK: - Constants

    private static let graphBase = "https://graph.microsoft.com/v1.0/me/drive"

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "OneDriveLargeFileUpload")

    // MARK: - Init

    public init() {}

    // MARK: - Step 1: Create Upload Session

    /// Creates an upload session for `remotePath` and returns the `uploadUrl`.
    ///
    /// - Parameters:
    ///   - remotePath: Destination path on OneDrive (e.g. `/Documents/video.mp4`).
    ///   - account: The authenticated cloud account.
    ///   - httpClient: HTTP client to use for the request.
    /// - Returns: The upload URL (used as the session identifier for subsequent chunk PUTs).
    public func createSession(
        remotePath: CloudPath,
        account: CloudAccount,
        httpClient: HTTPClient
    ) async throws -> String {
        guard let comps = URLComponents(string: "\(Self.graphBase)/root:\(remotePath.path):/createUploadSession") else {
            throw OneDriveLargeFileUploadError
                .invalidUploadURL("\(Self.graphBase)/root:\(remotePath.path):/createUploadSession")
        }
        guard let url = comps.url else {
            throw OneDriveLargeFileUploadError.invalidUploadURL(remotePath.path)
        }

        let payload: [String: Any] = [
            "item": [
                "@microsoft.graph.conflictBehavior": "replace",
                "name": remotePath.lastComponent
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = HTTPRequest(url: url, method: .POST)
        request.headers["Content-Type"] = "application/json"
        request.body = bodyData

        let response = try await httpClient.data(for: request)
        guard response.isSuccess else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw OneDriveLargeFileUploadError.sessionCreationFailed(statusCode: response.statusCode, body: body)
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let uploadURL = json["uploadUrl"] as? String
        else {
            throw OneDriveLargeFileUploadError.missingUploadURL
        }

        logger.info("OneDrive upload session created for \(remotePath.path, privacy: .private)")
        return uploadURL
    }

    // MARK: - Step 2: Upload Chunk

    /// Uploads a single byte-range chunk to an existing upload session.
    ///
    /// - Parameters:
    ///   - uploadURL: The URL returned by `createSession(remotePath:account:httpClient:)`.
    ///   - data: The chunk data.
    ///   - rangeStart: Zero-based byte offset of the first byte in `data`.
    ///   - totalSize: Total file size in bytes (required by the `Content-Range` header).
    ///   - httpClient: HTTP client to use for the request.
    /// - Returns: `true` when the server signals the upload is complete (HTTP 200 or 201);
    ///   `false` when the server acknowledges the chunk but expects more (HTTP 202).
    public func uploadChunk(
        uploadURL: String,
        data: Data,
        rangeStart: Int64,
        totalSize: Int64,
        httpClient: HTTPClient
    ) async throws -> Bool {
        guard let url = URL(string: uploadURL) else {
            throw OneDriveLargeFileUploadError.invalidUploadURL(uploadURL)
        }

        let rangeEnd = rangeStart + Int64(data.count) - 1
        let contentRange = "bytes \(rangeStart)-\(rangeEnd)/\(totalSize)"

        var request = HTTPRequest(url: url, method: .PUT)
        request.headers["Content-Length"] = "\(data.count)"
        request.headers["Content-Range"] = contentRange
        request.body = data

        let response = try await httpClient.upload(request: request, from: data)

        switch response.statusCode {
        case 200, 201:
            logger.info("OneDrive upload complete (status \(response.statusCode))")
            return true
        case 202:
            logger.debug("OneDrive chunk accepted, more expected (bytes \(rangeStart)-\(rangeEnd))")
            return false
        default:
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw OneDriveLargeFileUploadError.chunkUploadFailed(statusCode: response.statusCode, body: body)
        }
    }
}
