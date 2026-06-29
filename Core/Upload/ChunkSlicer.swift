import Foundation

// MARK: - Chunk Descriptor

public struct ChunkDescriptor: Sendable {
    public let number: Int       // 0-based
    public let offset: Int64
    public let size: Int
    public let isLast: Bool

    public init(number: Int, offset: Int64, size: Int, isLast: Bool) {
        self.number = number
        self.offset = offset
        self.size = size
        self.isLast = isLast
    }
}

// MARK: - Parallelism Config

public struct ParallelismConfig: Sendable {
    public let chunkSize: Int
    public let maxConcurrentChunks: Int
    public let maxConcurrentFiles: Int
    public let useHTTP2Multiplexing: Bool
    public let prefetchNextChunk: Bool

    public init(
        chunkSize: Int,
        maxConcurrentChunks: Int,
        maxConcurrentFiles: Int = 4,
        useHTTP2Multiplexing: Bool = true,
        prefetchNextChunk: Bool = true
    ) {
        self.chunkSize = chunkSize
        self.maxConcurrentChunks = maxConcurrentChunks
        self.maxConcurrentFiles = maxConcurrentFiles
        self.useHTTP2Multiplexing = useHTTP2Multiplexing
        self.prefetchNextChunk = prefetchNextChunk
    }
}

// MARK: - ChunkSlicer

public struct ChunkSlicer: Sendable {

    // MARK: - Chunk size strategy (adaptive, not fixed)
    //
    // < 5 MB:         single-part (no chunking)
    // 5–100 MB:       8 MB chunks, up to 8 parallel
    // 100 MB–1 GB:    16 MB chunks, up to 16 parallel
    // 1–10 GB:        32 MB chunks, up to 32 parallel
    // > 10 GB:        64 MB chunks, up to 32 parallel

    private static let MB = 1024 * 1024

    public static func slice(fileSize: Int64, chunkSize: Int) -> [ChunkDescriptor] {
        guard fileSize > 0 else {
            return [ChunkDescriptor(number: 0, offset: 0, size: 0, isLast: true)]
        }
        guard chunkSize > 0 else { return [] }

        var chunks: [ChunkDescriptor] = []
        var offset: Int64 = 0
        var number = 0

        while offset < fileSize {
            let remaining = fileSize - offset
            let size = Int(min(Int64(chunkSize), remaining))
            let isLast = offset + Int64(size) >= fileSize
            chunks.append(ChunkDescriptor(number: number, offset: offset, size: size, isLast: isLast))
            offset += Int64(size)
            number += 1
        }
        return chunks
    }

    public static func defaultChunkSize(for fileSize: Int64) -> Int {
        switch fileSize {
        case ..<Int64(5 * MB):         return fileSize == 0 ? MB : Int(fileSize)
        case ..<Int64(100 * MB):       return 8 * MB
        case ..<Int64(1024 * MB):      return 16 * MB
        case ..<Int64(10 * 1024 * MB): return 32 * MB
        default:                        return 64 * MB
        }
    }

    public static func defaultParallelism(for fileSize: Int64) -> Int {
        switch fileSize {
        case ..<Int64(5 * MB):         return 1
        case ..<Int64(100 * MB):       return 8
        case ..<Int64(1024 * MB):      return 16
        default:                        return 32
        }
    }

    public static func optimalConfig(
        fileSize: Int64,
        bandwidthBPS: Double,
        rtt: TimeInterval,
        capabilities: ProviderCapabilities
    ) -> ParallelismConfig {
        var chunkSize = defaultChunkSize(for: fileSize)
        var parallelism = defaultParallelism(for: fileSize)

        // High bandwidth: more parallelism
        if bandwidthBPS > 100 * 1024 * 1024 {  // > 100 MB/s
            parallelism = min(parallelism * 2, capabilities.maxConcurrentUploads)
        }

        // High RTT: fewer but larger chunks (amortize round-trip cost)
        if rtt > 0.2 {
            chunkSize = min(chunkSize * 2, capabilities.maxChunkSize)
            parallelism = max(1, parallelism / 2)
        }

        // Clamp to provider limits
        chunkSize = max(capabilities.minChunkSize, min(chunkSize, capabilities.maxChunkSize))
        parallelism = max(1, min(parallelism, capabilities.maxConcurrentUploads))

        // Never buffer > 512 MB in-flight
        let maxInFlight = 512 * MB
        let maxFromMemory = maxInFlight / chunkSize
        parallelism = min(parallelism, maxFromMemory)

        return ParallelismConfig(
            chunkSize: chunkSize,
            maxConcurrentChunks: max(1, parallelism),
            useHTTP2Multiplexing: true,
            prefetchNextChunk: bandwidthBPS > 0
        )
    }

    // Read a chunk safely using pread (thread-safe, no seek required)
    public static func readChunk(
        fileHandle: FileHandle,
        offset: Int64,
        size: Int
    ) throws -> Data {
        // pread is thread-safe unlike seek+read
        let fd = fileHandle.fileDescriptor
        var buffer = Data(count: size)
        let bytesRead = buffer.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return pread(fd, base, size, offset)
        }
        guard bytesRead >= 0 else {
            throw ChunkSlicerError.readFailed(errno: errno)
        }
        return buffer.prefix(bytesRead)
    }
}

public enum ChunkSlicerError: Error, Sendable {
    case readFailed(errno: Int32)
    case invalidOffset
    case fileTooLarge
}
