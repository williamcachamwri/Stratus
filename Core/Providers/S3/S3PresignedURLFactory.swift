import Foundation
import CryptoKit

// MARK: - S3PresignedURLFactory
// Generates AWS S3 presigned GET and PUT URLs using SigV4 query-string signing.
// All URL assembly goes through URLComponents — no string interpolation for URLs.

public struct S3PresignedURLFactory: Sendable {

    public init() {}

    // MARK: - Presigned GET

    /// Generates a presigned GET URL for `key` in `bucket`.
    /// - Parameters:
    ///   - bucket: S3 bucket name.
    ///   - key: Object key (no leading slash).
    ///   - region: AWS region, e.g. `"us-east-1"`.
    ///   - accessKeyID: AWS access key ID.
    ///   - secretKey: AWS secret access key.
    ///   - expiresIn: Validity window in seconds (max 604 800 for SigV4).
    /// - Returns: Presigned URL, or `nil` if URL assembly fails.
    public func presignedGetURL(
        bucket: String,
        key: String,
        region: String,
        accessKeyID: String,
        secretKey: String,
        expiresIn: TimeInterval
    ) -> URL? {
        guard let objectURL = buildObjectURL(bucket: bucket, key: key, region: region) else {
            return nil
        }
        return RequestSigner.presignedURL(
            url: objectURL,
            method: "GET",
            accessKeyID: accessKeyID,
            secretAccessKey: secretKey,
            region: region,
            service: "s3",
            expiresIn: min(expiresIn, 604_800)
        )
    }

    // MARK: - Presigned PUT

    /// Generates a presigned PUT URL for `key` in `bucket`.
    /// - Parameters:
    ///   - bucket: S3 bucket name.
    ///   - key: Object key (no leading slash).
    ///   - region: AWS region.
    ///   - accessKeyID: AWS access key ID.
    ///   - secretKey: AWS secret access key.
    ///   - expiresIn: Validity window in seconds (max 604 800).
    ///   - contentType: MIME type the PUT request must include as `Content-Type`.
    /// - Returns: Presigned URL, or `nil` if URL assembly fails.
    public func presignedPutURL(
        bucket: String,
        key: String,
        region: String,
        accessKeyID: String,
        secretKey: String,
        expiresIn: TimeInterval,
        contentType: String
    ) -> URL? {
        guard var objectURL = buildObjectURL(bucket: bucket, key: key, region: region) else {
            return nil
        }
        // Append content-type as an additional signed query parameter so the
        // caller must include the matching Content-Type header.
        guard var comps = URLComponents(url: objectURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = comps.queryItems ?? []
        queryItems.append(URLQueryItem(name: "x-amz-meta-content-type", value: contentType))
        comps.queryItems = queryItems
        guard let urlWithCT = comps.url else { return nil }
        objectURL = urlWithCT

        return RequestSigner.presignedURL(
            url: objectURL,
            method: "PUT",
            accessKeyID: accessKeyID,
            secretAccessKey: secretKey,
            region: region,
            service: "s3",
            expiresIn: min(expiresIn, 604_800)
        )
    }

    // MARK: - URL Construction (URLComponents only — no string interpolation)

    private func buildObjectURL(bucket: String, key: String, region: String) -> URL? {
        // Virtual-hosted style: https://<bucket>.s3.<region>.amazonaws.com/<key>
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "\(bucket).s3.\(region).amazonaws.com"
        // Ensure the key path starts with a slash.
        comps.path = key.hasPrefix("/") ? key : "/" + key
        return comps.url
    }
}
