import CryptoKit
import Foundation
import os.log

// MARK: - S3MultipartUpload

// Helper that encapsulates the three-step AWS S3 multipart-upload protocol:
//   1. CreateMultipartUpload  → obtain uploadID
//   2. UploadPart × N        → accumulate CompletedPart list
//   3. CompleteMultipartUpload / AbortMultipartUpload

public enum S3MultipartUploadError: Error, Sendable {
    case missingCredentials
    case initiationFailed(statusCode: Int, body: String)
    case partUploadFailed(partNumber: Int, statusCode: Int, body: String)
    case completionFailed(statusCode: Int, body: String)
    case missingETag(partNumber: Int)
    case missingUploadID
    case invalidResponse(String)
}

public actor S3MultipartUpload {
    // MARK: - State

    private let bucket: String
    private let key: String
    private let region: String
    private let accessKeyID: String
    private let secretKey: String
    private let sessionToken: String?
    private let endpoint: URL
    private let usePathStyle: Bool
    private let http: HTTPClient

    private var uploadID: String?
    private var completedParts: [CompletedPart] = []

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "S3MultipartUpload")

    // MARK: - Init

    public init(
        bucket: String,
        key: String,
        region: String,
        accessKeyID: String,
        secretKey: String,
        sessionToken: String? = nil,
        endpoint: URL? = nil,
        usePathStyle: Bool = false,
        http: HTTPClient = .shared
    ) {
        self.bucket = bucket
        self.key = key
        self.region = region
        self.accessKeyID = accessKeyID
        self.secretKey = secretKey
        self.sessionToken = sessionToken
        self.usePathStyle = usePathStyle
        self.http = http
        if let ep = endpoint {
            self.endpoint = ep
        } else {
            // Force-try is safe: the literal is always valid.
            self.endpoint = URL(string: "https://s3.\(region).amazonaws.com")
                ?? URL(string: "https://s3.amazonaws.com")! // fallback; literal always valid
        }
    }

    // MARK: - Step 1: Initiate

    /// Creates the multipart upload and stores the upload ID.
    /// - Parameter contentType: MIME type for the object.
    /// - Returns: The upload ID assigned by S3.
    @discardableResult
    public func initiate(contentType: String = "application/octet-stream") async throws -> String {
        let url = objectURL(query: "uploads")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        RequestSigner.signV4(
            request: &request,
            accessKeyID: accessKeyID,
            secretAccessKey: secretKey,
            sessionToken: sessionToken,
            region: region,
            service: "s3"
        )
        let response = try await http.data(for: HTTPRequest(
            url: url,
            method: .POST,
            headers: request.allHTTPHeaderFields ?? [:]
        ))
        guard response.isSuccess else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw S3MultipartUploadError.initiationFailed(statusCode: response.statusCode, body: body)
        }
        let id = try parseUploadID(from: response.data)
        uploadID = id
        logger.info("S3 multipart upload initiated: uploadID=\(id, privacy: .private)")
        return id
    }

    // MARK: - Step 2: Upload Part

    /// Uploads a single part.  Parts are numbered from 1.
    /// - Parameters:
    ///   - data: Chunk data (min 5 MiB for all parts except the last).
    ///   - partNumber: 1-based part index.
    /// - Returns: A `CompletedPart` ready to be passed to `complete()`.
    @discardableResult
    public func uploadPart(data: Data, partNumber: Int) async throws -> CompletedPart {
        guard let uid = uploadID else { throw S3MultipartUploadError.missingUploadID }

        let encodedUID = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uid
        let query = "partNumber=\(partNumber)&uploadId=\(encodedUID)"
        let url = objectURL(query: query)

        let md5Base64 = Data(Insecure.MD5.hash(data: data)).base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        RequestSigner.signV4(
            request: &request,
            accessKeyID: accessKeyID,
            secretAccessKey: secretKey,
            sessionToken: sessionToken,
            region: region,
            service: "s3"
        )

        let response = try await http.upload(
            request: HTTPRequest(url: url, method: .PUT, headers: request.allHTTPHeaderFields ?? [:]),
            from: data
        )
        guard response.isSuccess else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw S3MultipartUploadError.partUploadFailed(
                partNumber: partNumber,
                statusCode: response.statusCode,
                body: body
            )
        }
        guard let rawETag = response.headers["ETag"] ?? response.headers["etag"] else {
            throw S3MultipartUploadError.missingETag(partNumber: partNumber)
        }
        let etag = rawETag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let part = CompletedPart(partNumber: partNumber, etag: etag)
        completedParts.append(part)
        logger.debug("Uploaded part \(partNumber) etag=\(etag, privacy: .private)")
        return part
    }

    // MARK: - Step 3: Complete

    /// Sends the CompleteMultipartUpload request.
    /// Uses parts accumulated via `uploadPart`, or a caller-supplied override list.
    public func complete(parts overrideParts: [CompletedPart]? = nil) async throws {
        guard let uid = uploadID else { throw S3MultipartUploadError.missingUploadID }
        let parts = (overrideParts ?? completedParts).sorted { $0.partNumber < $1.partNumber }

        let encodedUID = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uid
        let url = objectURL(query: "uploadId=\(encodedUID)")

        let xmlParts = parts.map {
            "<Part><PartNumber>\($0.partNumber)</PartNumber><ETag>\($0.etag)</ETag></Part>"
        }.joined()
        let body = Data("<CompleteMultipartUpload>\(xmlParts)</CompleteMultipartUpload>".utf8)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        RequestSigner.signV4(
            request: &request,
            accessKeyID: accessKeyID,
            secretAccessKey: secretKey,
            sessionToken: sessionToken,
            region: region,
            service: "s3"
        )

        let response = try await http.upload(
            request: HTTPRequest(url: url, method: .POST, headers: request.allHTTPHeaderFields ?? [:]),
            from: body
        )
        guard response.isSuccess else {
            let body = String(data: response.data, encoding: .utf8) ?? ""
            throw S3MultipartUploadError.completionFailed(statusCode: response.statusCode, body: body)
        }
        logger.info("S3 multipart upload completed: key=\(self.key, privacy: .private)")
    }

    // MARK: - Abort

    /// Aborts the in-progress multipart upload.  Errors are logged, not rethrown.
    public func abort() async {
        guard let uid = uploadID else { return }
        let encodedUID = uid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? uid
        let url = objectURL(query: "uploadId=\(encodedUID)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        RequestSigner.signV4(
            request: &request,
            accessKeyID: accessKeyID,
            secretAccessKey: secretKey,
            sessionToken: sessionToken,
            region: region,
            service: "s3"
        )
        do {
            _ = try await http.data(for: HTTPRequest(
                url: url,
                method: .DELETE,
                headers: request.allHTTPHeaderFields ?? [:]
            ))
        } catch {
            logger.warning("S3 abort failed: \(error)")
        }
    }

    // MARK: - URL Helpers

    private func objectURL(query: String? = nil) -> URL {
        let base: URL
        if usePathStyle {
            base = endpoint
                .appendingPathComponent(bucket)
                .appendingPathComponent(key)
        } else {
            var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
                ?? URLComponents()
            comps.host = "\(bucket).\(comps.host ?? "")"
            comps.path = "/\(key)"
            base = comps.url ?? endpoint.appendingPathComponent(key)
        }
        guard let q = query else { return base }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        comps.query = q
        return comps.url ?? base
    }

    // MARK: - XML Parsing

    private func parseUploadID(from data: Data) throws -> String {
        let xml = String(data: data, encoding: .utf8) ?? ""
        guard let id = xml
            .components(separatedBy: "<UploadId>").dropFirst().first?
            .components(separatedBy: "</UploadId>").first
        else {
            throw S3MultipartUploadError.invalidResponse("No UploadId element in response")
        }
        return id
    }
}
