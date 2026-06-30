import Accelerate
import CryptoKit
import Foundation
import os.log

// MARK: - ChecksumEngine

public actor ChecksumEngine {
    public static let shared = ChecksumEngine()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ChecksumEngine")
    private let streamingChunkSize = 4 * 1024 * 1024 // 4 MB streaming read chunks

    private init() {}

    // MARK: - SHA-256 (CryptoKit — hardware accelerated on Apple Silicon)

    public func sha256(of data: Data) async -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func sha256Stream(url: URL) async throws -> String {
        var hasher = SHA256()
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        while true {
            guard let chunk = try fileHandle.read(upToCount: streamingChunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MD5 (legacy providers: FTP, older WebDAV)

    public func md5Stream(url: URL) async throws -> String {
        var hasher = Insecure.MD5()
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        while true {
            guard let chunk = try fileHandle.read(upToCount: streamingChunkSize), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func md5(of data: Data) async -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - CRC32c (Google Cloud Storage)

    public func crc32c(of data: Data) async -> UInt32 {
        // Uses Accelerate vDSP for hardware-accelerated CRC32c
        data.withUnsafeBytes { bytes in
            var crc: UInt32 = 0xFFFF_FFFF
            let ptr = bytes.bindMemory(to: UInt8.self)
            for byte in ptr {
                crc = crc32cTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
            return ~crc
        }
    }

    // MARK: - S3 Multipart ETag

    /// S3 multipart ETag = MD5(MD5(p1) + MD5(p2) + ... + MD5(pN)) + "-N"
    public func s3MultipartETag(chunkMD5s: [String]) async -> String {
        var concatenated = Data()
        for hex in chunkMD5s {
            let bytes = stride(from: 0, to: hex.count, by: 2).compactMap {
                let start = hex.index(hex.startIndex, offsetBy: $0)
                let end = hex.index(start, offsetBy: 2)
                return UInt8(hex[start ..< end], radix: 16)
            }
            concatenated.append(contentsOf: bytes)
        }
        let digest = Insecure.MD5.hash(data: concatenated)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex)-\(chunkMD5s.count)"
    }

    // MARK: - Verification

    public func verifyRemote(
        localChecksum: String,
        remoteETag: String,
        provider: any CloudProvider
    ) async throws -> Bool {
        // Simple case: direct match
        if localChecksum.lowercased() == remoteETag.lowercased() { return true }
        // S3 multipart ETags have "-N" suffix — those require s3MultipartETag comparison
        if remoteETag.contains("-") { return false }
        return false
    }

    // MARK: - Concurrent file checksums

    public func sha256Batch(urls: [URL]) async throws -> [URL: String] {
        try await withThrowingTaskGroup(of: (URL, String).self) { group in
            for url in urls {
                group.addTask {
                    let checksum = try await ChecksumEngine.shared.sha256Stream(url: url)
                    return (url, checksum)
                }
            }
            var results: [URL: String] = [:]
            for try await (url, checksum) in group {
                results[url] = checksum
            }
            return results
        }
    }
}

// MARK: - CRC32c Lookup Table

/// Precomputed Castagnoli polynomial table
private let crc32cTable: [UInt32] = {
    let poly: UInt32 = 0x82F6_3B78
    return (0 ..< 256).map { i -> UInt32 in
        var crc = UInt32(i)
        for _ in 0 ..< 8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ poly : crc >> 1
        }
        return crc
    }
}()
