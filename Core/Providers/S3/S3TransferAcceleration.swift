import Foundation

// MARK: - S3TransferAcceleration

// Selects between the standard S3 regional endpoint and the S3 Transfer
// Acceleration endpoint (bucket.s3-accelerate.amazonaws.com).
//
// Transfer Acceleration routes uploads through CloudFront edge locations,
// reducing latency for geographically distant clients.  It must be enabled
// on the bucket via the S3 console or API before use.

public struct S3TransferAcceleration: Sendable {
    // MARK: - Configuration

    /// When `true`, `acceleratedEndpoint(for:)` returns the acceleration
    /// endpoint.  When `false`, it returns the standard regional endpoint.
    public var isEnabled: Bool

    /// The AWS region used when building the standard (non-accelerated) endpoint.
    public let region: String

    // MARK: - Init

    public init(isEnabled: Bool = false, region: String = "us-east-1") {
        self.isEnabled = isEnabled
        self.region = region
    }

    // MARK: - Endpoint Selection

    /// Returns the appropriate S3 endpoint URL for `bucket`.
    ///
    /// - Acceleration on:  `https://<bucket>.s3-accelerate.amazonaws.com`
    /// - Acceleration off: `https://s3.<region>.amazonaws.com`
    ///
    /// URL is assembled with `URLComponents` — no string interpolation.
    public func acceleratedEndpoint(for bucket: String) -> URL {
        var comps = URLComponents()
        comps.scheme = "https"
        if isEnabled {
            // Transfer Acceleration endpoint: bucket-specific subdomain
            comps.host = "\(bucket).s3-accelerate.amazonaws.com"
            comps.path = "/"
        } else {
            // Standard regional endpoint (path-style root)
            comps.host = "s3.\(region).amazonaws.com"
            comps.path = "/"
        }
        // URLComponents.url is only nil when the components are malformed.
        // Both branches above set a valid scheme and host, so comps.url is
        // never nil here.  The fallback URL is expressed as a fileURLWithPath
        // to avoid any optional-URL construction.
        return comps.url ?? URL(fileURLWithPath: "/") // unreachable; satisfies compiler
    }

    /// Convenience: returns the virtual-hosted style object URL.
    ///
    /// - Parameters:
    ///   - bucket: S3 bucket name.
    ///   - key: Object key (no leading slash).
    public func objectURL(bucket: String, key: String) -> URL {
        let base = acceleratedEndpoint(for: bucket)
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            ?? URLComponents()
        if isEnabled {
            // Already bucket-addressed; key becomes the path.
            comps.path = key.hasPrefix("/") ? key : "/" + key
        } else {
            // Path-style: /<bucket>/<key>
            comps.path = "/\(bucket)/\(key)"
        }
        return comps.url ?? base.appendingPathComponent(key)
    }
}
