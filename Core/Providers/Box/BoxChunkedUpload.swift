import CommonCrypto
import Foundation
import os.log

// MARK: - BoxChunkedUpload

// Implements the Box Chunked Upload API.
// Flow:
//   1. createSession  — POST /files/upload_sessions
//   2. uploadChunk    — PUT  /files/upload_sessions/{id}  (repeated per chunk)
//   3. commit         — POST /files/upload_sessions/{id}/commit

public actor BoxChunkedUpload {
    private static let uploadBase = "https://upload.box.com/api/2.0"

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BoxChunkedUpload")

    public init() {}

    // MARK: - Step 1: Create Session

    /// Creates a Box chunked upload session.
    /// - Returns: The session ID string used for subsequent chunk uploads and commit.
    public func createSession(
        fileSize: Int64,
        fileName: String,
        folderID: String,
        httpClient: HTTPClient
    ) async throws -> String {
        guard let url = URL(string: "\(Self.uploadBase)/files/upload_sessions") else {
            throw BoxChunkedUploadError.invalidURL
        }

        let payload: [String: Any] = [
            "folder_id": folderID,
            "file_name": fileName,
            "file_size": fileSize
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let request = HTTPRequest(
            url: url,
            method: .POST,
            headers: ["Content-Type": "application/json"],
            body: body
        )

        let response = try await httpClient.data(for: request)
        guard response.isSuccess else {
            throw BoxChunkedUploadError.sessionCreationFailed(statusCode: response.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let sessionID = json["id"] as? String
        else {
            throw BoxChunkedUploadError.invalidResponse("Expected session id in createSession response")
        }

        logger.info("Box upload session created: \(sessionID) for file '\(fileName)' (\(fileSize) bytes)")
        return sessionID
    }

    // MARK: - Step 2: Upload Chunk

    /// Uploads a single chunk to an existing Box upload session.
    /// - Parameters:
    ///   - sessionID: The upload session ID returned by `createSession`.
    ///   - data: The chunk bytes to upload.
    ///   - offset: Byte offset of this chunk within the complete file.
    ///   - totalSize: Total file size in bytes.
    ///   - partSHA1: Base64-encoded SHA-1 digest of `data`.
    /// - Returns: The `part_id` string assigned by Box for this chunk.
    public func uploadChunk(
        sessionID: String,
        data: Data,
        offset: Int64,
        totalSize: Int64,
        partSHA1: String,
        httpClient: HTTPClient
    ) async throws -> String {
        guard let url = URL(string: "\(Self.uploadBase)/files/upload_sessions/\(sessionID)") else {
            throw BoxChunkedUploadError.invalidURL
        }

        let rangeEnd = offset + Int64(data.count) - 1
        let headers: [String: String] = [
            "Content-Type": "application/octet-stream",
            "Content-Range": "bytes \(offset)-\(rangeEnd)/\(totalSize)",
            "Digest": "sha=\(partSHA1)"
        ]

        let request = HTTPRequest(url: url, method: .PUT, headers: headers, body: data)
        let response = try await httpClient.data(for: request)

        guard response.isSuccess || response.statusCode == 200 else {
            throw BoxChunkedUploadError.chunkUploadFailed(statusCode: response.statusCode, offset: offset)
        }

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let part = json["part"] as? [String: Any],
              let partID = part["part_id"] as? String
        else {
            throw BoxChunkedUploadError.invalidResponse("Expected part_id in uploadChunk response")
        }

        logger.debug("Box chunk uploaded: part_id=\(partID) offset=\(offset)")
        return partID
    }

    // MARK: - Step 3: Commit

    /// Commits all uploaded parts, completing the chunked upload.
    /// - Parameters:
    ///   - sessionID: The upload session ID.
    ///   - parts: An array of (id, offset, size) tuples describing every uploaded part.
    ///   - sha1: Base64-encoded SHA-1 digest of the complete file.
    public func commit(
        sessionID: String,
        parts: [(id: String, offset: Int64, size: Int64)],
        sha1: String,
        httpClient: HTTPClient
    ) async throws {
        guard let url = URL(string: "\(Self.uploadBase)/files/upload_sessions/\(sessionID)/commit") else {
            throw BoxChunkedUploadError.invalidURL
        }

        let partsPayload: [[String: Any]] = parts.map { part in
            [
                "part_id": part.id,
                "offset": part.offset,
                "size": part.size
            ]
        }
        let payload: [String: Any] = ["parts": partsPayload]
        let body = try JSONSerialization.data(withJSONObject: payload)

        let headers: [String: String] = [
            "Content-Type": "application/json",
            "Digest": "sha=\(sha1)"
        ]

        let request = HTTPRequest(url: url, method: .POST, headers: headers, body: body)
        let response = try await httpClient.data(for: request)

        // Box returns 201 Created or 202 Accepted (still processing)
        guard response.isSuccess || response.statusCode == 201 || response.statusCode == 202 else {
            throw BoxChunkedUploadError.commitFailed(statusCode: response.statusCode)
        }

        logger.info("Box upload session \(sessionID) committed successfully")
    }
}

// MARK: - BoxChunkedUploadError

public enum BoxChunkedUploadError: Error, Sendable {
    case invalidURL
    case sessionCreationFailed(statusCode: Int)
    case chunkUploadFailed(statusCode: Int, offset: Int64)
    case commitFailed(statusCode: Int)
    case invalidResponse(String)
}

// MARK: - Data SHA-1 helper

private extension Data {
    func sha1Base64() -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(count), &digest)
        }
        return Data(digest).base64EncodedString()
    }
}
