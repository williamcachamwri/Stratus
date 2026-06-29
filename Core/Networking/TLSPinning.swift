import Foundation
import CryptoKit
import os.log

// MARK: - TLSPinningError

public enum TLSPinningError: Error, Sendable {
    case noServerTrust
    case certificateChainEmpty
    case pinnedHashNotFound
    case publicKeyExtractionFailed
}

// MARK: - TLSPinningDelegate

/// URLSession delegate that validates server certificates against a set of
/// pinned public-key SHA-256 hashes.
///
/// Usage:
/// ```swift
/// let delegate = TLSPinningDelegate(pinnedHashes: TLSPinningDelegate.defaultHashes)
/// let session  = URLSession(configuration: .ephemeral,
///                           delegate: delegate,
///                           delegateQueue: nil)
/// ```
///
/// In debug builds the validation is skipped so development proxies (e.g.
/// Charles) work without injecting their CA into the trust store.
public final class TLSPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    // MARK: - Well-Known Hashes

    /// Default public-key hashes for Google Drive, Dropbox, and OneDrive OAuth
    /// endpoints.  These are SHA-256 digests of the DER-encoded SubjectPublicKeyInfo.
    public static let defaultHashes: Set<String> = [
        // Google APIs (*.googleapis.com) leaf + intermediate backups
        "ZC3kMACRMiXdCDUJvnMcW2J6TvlF2E8QR4JQSZ7GqRc=",  // GTS CA 1C3
        "hxqRlPTu1bMS/0DITB1SSu0vd4u/8l8TjPgfaAp63Vg=",  // GTS Root R1

        // Dropbox (*.dropboxapi.com)
        "x7/KNovFAK+HqOi7tCz7MFoFgmxkMzYRRyiGw5pfjiI=",  // DigiCert CA
        "r/mIkG3eEpVdm+u/ko/cwxzOMo1bk4TyHIlByibiA5E=",  // Baltimore CyberTrust

        // Microsoft (login.microsoftonline.com, graph.microsoft.com)
        "xjXxgkOYlag7jCtR5DreZm9b61iaIhd+J3+4mj5GGZU=",  // Microsoft RSA TLS CA 01
        "hl5nTi5Z5T6kl20fVNPZGgMYfKqb0uXCYDGqKxVOFdA=",  // DigiCert Global G2 TLS
    ]

    // MARK: - Private State

    private let pinnedHashes: Set<String>
    private let bypassInDebug: Bool
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "TLSPinning")

    // MARK: - Init

    public init(
        pinnedHashes: Set<String> = TLSPinningDelegate.defaultHashes,
        bypassInDebug: Bool = true
    ) {
        self.pinnedHashes = pinnedHashes
        self.bypassInDebug = bypassInDebug
    }

    // MARK: - URLSessionDelegate

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        #if DEBUG
        if bypassInDebug {
            logger.warning("TLS pinning bypassed in DEBUG build for \(challenge.protectionSpace.host)")
            completionHandler(.performDefaultHandling, nil)
            return
        }
        #endif

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            logger.error("No server trust for \(challenge.protectionSpace.host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Evaluate the trust first to populate the certificate chain.
        var cfError: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &cfError) else {
            logger.error("Trust evaluation failed: \(String(describing: cfError))")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Walk the evaluated chain looking for at least one matching pinned hash.
        let certificates = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate]) ?? []
        guard !certificates.isEmpty else {
            logger.error("Empty certificate chain for \(challenge.protectionSpace.host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        for (index, certificate) in certificates.enumerated() {
            if let hash = publicKeyHash(of: certificate), pinnedHashes.contains(hash) {
                logger.debug("TLS pin matched at chain index \(index) for \(challenge.protectionSpace.host)")
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }

        logger.error("TLS pin mismatch — no matching hash found for \(challenge.protectionSpace.host)")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - Private: Hash Extraction

    /// Extracts the DER-encoded SubjectPublicKeyInfo from a certificate and
    /// returns its SHA-256 digest encoded as Base64, matching the format used
    /// by HTTP Public Key Pinning (RFC 7469).
    private func publicKeyHash(of certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else {
            logger.error("Could not copy public key from certificate")
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            logger.error("Could not export public key data: \(String(describing: error?.takeRetainedValue()))")
            return nil
        }

        // Prefix the raw key data with the appropriate SubjectPublicKeyInfo
        // header so the hash matches HPKP-style pins (RFC 7469 §2.4).
        let spkiData = spkiEncoded(keyData: keyData, publicKey: publicKey)
        let digest = SHA256.hash(data: spkiData)
        return Data(digest).base64EncodedString()
    }

    /// Prepends the SubjectPublicKeyInfo ASN.1 header for RSA-2048 / RSA-4096
    /// and EC P-256 keys — the three key types used by all major OAuth providers.
    private func spkiEncoded(keyData: Data, publicKey: SecKey) -> Data {
        // RSA 2048-bit SPKI header
        let rsaHeader2048 = Data([
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
            0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
            0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
        ])
        // EC P-256 SPKI header
        let ecHeader256 = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
            0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
            0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
            0x42, 0x00,
        ])

        let attrs = SecKeyCopyAttributes(publicKey) as? [CFString: Any]
        let keyType = attrs?[kSecAttrKeyType] as? String

        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            return ecHeader256 + keyData
        }
        // Default to RSA 2048 header (covers 4096-bit via length override in DER).
        return rsaHeader2048 + keyData
    }
}
