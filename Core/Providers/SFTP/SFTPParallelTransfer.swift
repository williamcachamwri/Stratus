import Citadel
import Foundation
import NIOCore
import os.log

// MARK: - SFTPParallelTransfer

// Uploads or downloads a file using windowed sequential SFTP operations.
// SFTPFile (Citadel) is non-Sendable and channel-bound; we use pipelined
// window writes/reads on a single channel rather than concurrent tasks.

public actor SFTPParallelTransfer {
    /// Size of each transfer window in bytes (SSH-packet-friendly).
    private static let windowSize = 32 * 1024 // 32 KB

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SFTPParallelTransfer")

    public init() {}

    // MARK: - Upload

    /// Uploads `data` to `remotePath` using the provided session.
    public func upload(
        data: Data,
        remotePath: CloudPath,
        session: SFTPSession
    ) async throws {
        logger.info("SFTP upload \(data.count) bytes to \(remotePath.path)")
        try await windowedUpload(data: data, remotePath: remotePath, session: session)
    }

    // MARK: - Download

    /// Downloads the file at `remotePath` using the provided session.
    public func download(
        remotePath: CloudPath,
        session: SFTPSession
    ) async throws -> Data {
        logger.info("SFTP download from \(remotePath.path)")
        return try await windowedDownload(remotePath: remotePath, session: session)
    }

    // MARK: - Private Upload

    private func windowedUpload(
        data: Data,
        remotePath: CloudPath,
        session: SFTPSession
    ) async throws {
        let file = try await session.client.openFile(
            filePath: remotePath.path,
            flags: [.write, .create, .truncate]
        )
        do {
            let windowSize = Self.windowSize
            var offset = 0
            while offset < data.count {
                let length = min(windowSize, data.count - offset)
                let slice = data[offset ..< (offset + length)]
                var buffer = ByteBufferAllocator().buffer(capacity: length)
                buffer.writeBytes(slice)
                try await file.write(buffer, at: UInt64(offset))
                offset += length
            }
            try? await file.close()
        } catch {
            try? await file.close()
            throw error
        }
    }

    // MARK: - Private Download

    private func windowedDownload(
        remotePath: CloudPath,
        session: SFTPSession
    ) async throws -> Data {
        let attrs = try await session.client.getAttributes(at: remotePath.path)
        guard let fileSize = attrs.size, fileSize > 0 else {
            return Data()
        }

        let file = try await session.client.openFile(filePath: remotePath.path, flags: .read)
        do {
            let totalSize = Int(fileSize)
            let windowSize = Self.windowSize
            var assembled = Data(capacity: totalSize)
            var offset = 0
            while offset < totalSize {
                let length = min(windowSize, totalSize - offset)
                let buffer = try await file.read(from: UInt64(offset), length: UInt32(length))
                var mutableBuffer = buffer
                if let chunk = mutableBuffer.readData(length: mutableBuffer.readableBytes) {
                    assembled.append(chunk)
                }
                offset += length
            }
            try? await file.close()
            return assembled
        } catch {
            try? await file.close()
            throw error
        }
    }
}

// MARK: - SFTPTransferError

public enum SFTPTransferError: Error, Sendable {
    case parallelUnsupported
    case readFailed(String)
    case writeFailed(String)
    case fileSizeUnavailable
}
