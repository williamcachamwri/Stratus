import CryptoKit
import Foundation
import os.log

// MARK: - BackblazeMultipartUpload

// Implements the Backblaze B2 native large-file API (non-S3-compatible):
//
//   1. b2_start_large_file   → fileId
//   2. b2_get_upload_part_url (per part)
//   3. b2_upload_part × N    → accumulate sha1 array
//   4. b2_finish_large_file  → complete

public enum BackblazeMultipartUploadError: Error, Sendable {
    case missingAuthToken
    case missingAPIURL
    case startFailed(statusCode: Int, body: String)
    case getUploadPartURLFailed(statusCode: Int, body: String)
    case uploadPartFailed(partNumber: Int, statusCode: Int, body: String)
    case finishFailed(statusCode: Int, body: String)
    case invalidResponse(String)
    case missingFileID
}

public struct BackblazeMultipartUpload: Sendable {
    // MARK: - Configuration

    public let applicationKeyID: String
    public let applicationKey: String
    public let bucketID: String
    public let fileName: String

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "BackblazeMultipartUpload")

    // MARK: - Init

    public init(
        applicationKeyID: String,
        applicationKey: String,
        bucketID: String,
        fileName: String
    ) {
        self.applicationKeyID = applicationKeyID
        self.applicationKey = applicationKey
        self.bucketID = bucketID
        self.fileName = fileName
    }

    // MARK: - Full Upload Flow

    /// Executes the full three-step Backblaze B2 large-file upload.
    ///
    /// - Parameters:
    ///   - chunks: Ordered sequence of `Data` chunks.
    ///   - contentType: MIME type of the file.
    ///   - httpClient: HTTP client instance.
    ///   - authToken: B2 authorization token from b2_authorize_account.
    ///   - apiURL: API URL from b2_authorize_account (e.g. `https://apiNNN.backblazeb2.com`).
    /// - Returns: The B2 `fileId` of the completed file.
    @discardableResult
    public func upload(
        chunks: [Data],
        contentType: String = "application/octet-stream",
        httpClient: HTTPClient,
        authToken: String,
        apiURL: URL
    ) async throws -> String {
        // 1. Start large file
        let fileID = try await startLargeFile(
            contentType: contentType,
            httpClient: httpClient,
            authToken: authToken,
            apiURL: apiURL
        )

        // 2 & 3. Upload parts
        var partSHA1s: [String] = []
        for (index, chunk) in chunks.enumerated() {
            let partNumber = index + 1
            let (partUploadURL, partAuthToken) = try await getUploadPartURL(
                fileID: fileID,
                httpClient: httpClient,
                authToken: authToken,
                apiURL: apiURL
            )
            let sha1 = try await uploadPart(
                partNumber: partNumber,
                data: chunk,
                uploadURL: partUploadURL,
                authToken: partAuthToken,
                httpClient: httpClient
            )
            partSHA1s.append(sha1)
            logger.debug("B2 uploaded part \(partNumber)/\(chunks.count)")
        }

        // 4. Finish
        try await finishLargeFile(
            fileID: fileID,
            partSHA1s: partSHA1s,
            httpClient: httpClient,
            authToken: authToken,
            apiURL: apiURL
        )

        logger.info("B2 large file upload complete: fileId=\(fileID, privacy: .private)")
        return fileID
    }

    // MARK: - Step 1: b2_start_large_file

    private func startLargeFile(
        contentType: String,
        httpClient: HTTPClient,
        authToken: String,
        apiURL: URL
    ) async throws -> String {
        let url = apiURL.appendingPathComponent("b2api/v2/b2_start_large_file")
        let payload: [String: Any] = [
            "bucketId": bucketID,
            "fileName": fileName,
            "contentType": contentType
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var req = HTTPRequest(url: url, method: .POST)
        req.headers["Authorization"] = authToken
        req.headers["Content-Type"] = "application/json"
        req.body = body

        let response = try await httpClient.data(for: req)
        guard response.isSuccess else {
            let text = String(data: response.data, encoding: .utf8) ?? ""
            throw BackblazeMultipartUploadError.startFailed(statusCode: response.statusCode, body: text)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let fileID = json["fileId"] as? String
        else {
            throw BackblazeMultipartUploadError.missingFileID
        }
        return fileID
    }

    // MARK: - Step 2: b2_get_upload_part_url

    private func getUploadPartURL(
        fileID: String,
        httpClient: HTTPClient,
        authToken: String,
        apiURL: URL
    ) async throws -> (URL, String) {
        let url = apiURL.appendingPathComponent("b2api/v2/b2_get_upload_part_url")
        let payload: [String: Any] = ["fileId": fileID]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var req = HTTPRequest(url: url, method: .POST)
        req.headers["Authorization"] = authToken
        req.headers["Content-Type"] = "application/json"
        req.body = body

        let response = try await httpClient.data(for: req)
        guard response.isSuccess else {
            let text = String(data: response.data, encoding: .utf8) ?? ""
            throw BackblazeMultipartUploadError.getUploadPartURLFailed(statusCode: response.statusCode, body: text)
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let uploadURLStr = json["uploadUrl"] as? String,
              let partURL = URL(string: uploadURLStr),
              let partToken = json["authorizationToken"] as? String
        else {
            throw BackblazeMultipartUploadError.invalidResponse("Missing uploadUrl or authorizationToken")
        }
        return (partURL, partToken)
    }

    // MARK: - Step 3: b2_upload_part

    private func uploadPart(
        partNumber: Int,
        data: Data,
        uploadURL: URL,
        authToken: String,
        httpClient: HTTPClient
    ) async throws -> String {
        let sha1 = Insecure.SHA1.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()

        var req = HTTPRequest(url: uploadURL, method: .PUT)
        req.headers["Authorization"] = authToken
        req.headers["X-Bz-Part-Number"] = "\(partNumber)"
        req.headers["X-Bz-Content-Sha1"] = sha1
        req.headers["Content-Length"] = "\(data.count)"
        req.body = data

        let response = try await httpClient.upload(request: req, from: data)
        guard response.isSuccess else {
            let text = String(data: response.data, encoding: .utf8) ?? ""
            throw BackblazeMultipartUploadError.uploadPartFailed(
                partNumber: partNumber,
                statusCode: response.statusCode,
                body: text
            )
        }
        return sha1
    }

    // MARK: - Step 4: b2_finish_large_file

    private func finishLargeFile(
        fileID: String,
        partSHA1s: [String],
        httpClient: HTTPClient,
        authToken: String,
        apiURL: URL
    ) async throws {
        let url = apiURL.appendingPathComponent("b2api/v2/b2_finish_large_file")
        let payload: [String: Any] = [
            "fileId": fileID,
            "partSha1Array": partSHA1s
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        var req = HTTPRequest(url: url, method: .POST)
        req.headers["Authorization"] = authToken
        req.headers["Content-Type"] = "application/json"
        req.body = body

        let response = try await httpClient.data(for: req)
        guard response.isSuccess else {
            let text = String(data: response.data, encoding: .utf8) ?? ""
            throw BackblazeMultipartUploadError.finishFailed(statusCode: response.statusCode, body: text)
        }
    }
}
