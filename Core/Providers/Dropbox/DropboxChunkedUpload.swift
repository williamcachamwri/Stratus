import Foundation
import os.log

// MARK: - Dropbox Upload Session
// Dropbox upload_session API is SEQUENTIAL — no parallel chunks per session.
// Max chunk size: 150 MB. Session valid 48 hours with activity.

public actor DropboxChunkedUpload {
    private static let maxChunkSize = 150 * 1024 * 1024  // 150 MB
    private static let defaultChunkSize = 50 * 1024 * 1024  // 50 MB
    private let http = HTTPClient()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DropboxUpload")

    public init() {}

    // Step 1: Start session
    public func startSession(accessToken: String) async throws -> String {
        var request = HTTPRequest(
            url: URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!,
            method: .POST
        )
        request.headers["Authorization"] = "Bearer \(accessToken)"
        request.headers["Dropbox-API-Arg"] = "{\"close\":false}"
        request.headers["Content-Type"] = "application/octet-stream"
        request.body = Data()

        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let sessionID = json["session_id"] as? String else {
            throw DropboxError.sessionStartFailed(response.statusCode)
        }
        return sessionID
    }

    // Step 2: Append chunk (sequential)
    public func appendChunk(sessionID: String, data: Data, offset: Int64, isLast: Bool, accessToken: String) async throws {
        let cursorJSON = "{\"session_id\":\"\(sessionID)\",\"offset\":\(offset)}"
        let apiArg = "{\"cursor\":\(cursorJSON),\"close\":\(isLast)}"

        var request = HTTPRequest(
            url: URL(string: "https://content.dropboxapi.com/2/files/upload_session/append_v2")!,
            method: .POST
        )
        request.headers["Authorization"] = "Bearer \(accessToken)"
        request.headers["Dropbox-API-Arg"] = apiArg
        request.headers["Content-Type"] = "application/octet-stream"
        request.body = data

        let response = try await http.data(for: request)
        guard response.isSuccess || response.statusCode == 200 else {
            throw DropboxError.appendFailed(response.statusCode)
        }
    }

    // Step 3: Finish (commit)
    public func finishSession(
        sessionID: String,
        offset: Int64,
        remotePath: String,
        accessToken: String
    ) async throws -> String {  // returns file ID
        let cursorJSON = "{\"session_id\":\"\(sessionID)\",\"offset\":\(offset)}"
        let commitJSON = "{\"path\":\"\(remotePath)\",\"mode\":\"overwrite\",\"autorename\":false}"
        let apiArg = "{\"cursor\":\(cursorJSON),\"commit\":\(commitJSON)}"

        var request = HTTPRequest(
            url: URL(string: "https://content.dropboxapi.com/2/files/upload_session/finish")!,
            method: .POST
        )
        request.headers["Authorization"] = "Bearer \(accessToken)"
        request.headers["Dropbox-API-Arg"] = apiArg
        request.headers["Content-Type"] = "application/octet-stream"
        request.body = Data()

        let response = try await http.data(for: request)
        guard response.isSuccess,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let id = json["id"] as? String else {
            throw DropboxError.finishFailed(response.statusCode)
        }
        return id
    }

    // Full file upload orchestration
    public func upload(
        fileURL: URL,
        fileSize: Int64,
        remotePath: String,
        accessToken: String,
        progressHandler: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> String {
        let sessionID = try await startSession(accessToken: accessToken)
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        var offset: Int64 = 0
        while offset < fileSize {
            let chunkSize = Int(min(Int64(Self.defaultChunkSize), fileSize - offset))
            let data = try ChunkSlicer.readChunk(fileHandle: fileHandle, offset: offset, size: chunkSize)
            let isLast = offset + Int64(chunkSize) >= fileSize

            try await appendChunk(sessionID: sessionID, data: data, offset: offset, isLast: isLast && !isLast, accessToken: accessToken)
            offset += Int64(chunkSize)
            progressHandler(offset, fileSize)
        }

        return try await finishSession(sessionID: sessionID, offset: fileSize, remotePath: remotePath, accessToken: accessToken)
    }
}

public enum DropboxError: Error, Sendable {
    case sessionStartFailed(Int)
    case appendFailed(Int)
    case finishFailed(Int)
    case rateLimited
}
