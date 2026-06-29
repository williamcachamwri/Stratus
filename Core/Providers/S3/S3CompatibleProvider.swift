import Foundation

// MARK: - S3-Compatible Provider Factory
// Wasabi, Backblaze B2, Cloudflare R2, MinIO all reuse S3Provider with different endpoints.

public enum S3CompatibleProviders {

    public static func wasabi(bucket: String, region: String = "us-east-1") -> S3Provider {
        let endpoint = URL(string: "https://s3.\(region).wasabisys.com")!
        return S3Provider(
            id: "wasabi",
            displayName: "Wasabi",
            iconName: "wasabi",
            config: S3Configuration(endpoint: endpoint, region: region, bucket: bucket)
        )
    }

    public static func backblazeB2(bucket: String, region: String) -> S3Provider {
        // B2 S3-compatible endpoint: s3.<region>.backblazeb2.com
        let endpoint = URL(string: "https://s3.\(region).backblazeb2.com")!
        return S3Provider(
            id: "backblaze_b2",
            displayName: "Backblaze B2",
            iconName: "backblaze",
            config: S3Configuration(endpoint: endpoint, region: region, bucket: bucket)
        )
    }

    public static func cloudflareR2(bucket: String, accountID: String) -> S3Provider {
        let endpoint = URL(string: "https://\(accountID).r2.cloudflarestorage.com")!
        return S3Provider(
            id: "cloudflare_r2",
            displayName: "Cloudflare R2",
            iconName: "cloudflare",
            config: S3Configuration(endpoint: endpoint, region: "auto", bucket: bucket, usePathStyleURL: true)
        )
    }

    public static func minIO(endpoint: URL, bucket: String) -> S3Provider {
        return S3Provider(
            id: "minio",
            displayName: "MinIO",
            iconName: "minio",
            config: S3Configuration(endpoint: endpoint, region: "us-east-1", bucket: bucket, usePathStyleURL: true)
        )
    }

    public static func custom(endpoint: URL, bucket: String, region: String, providerID: String, displayName: String) -> S3Provider {
        return S3Provider(
            id: providerID,
            displayName: displayName,
            iconName: "s3",
            config: S3Configuration(endpoint: endpoint, region: region, bucket: bucket, usePathStyleURL: true)
        )
    }
}
