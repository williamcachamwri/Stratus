import Foundation
import os.log

// MARK: - Block Diff

public struct BlockDiff: Sendable {
    public let changedBlocks: [Int]   // indices of changed blocks
    public let addedBlocks: [Int]     // new blocks (file grew)
    public let removedBlocks: [Int]   // removed blocks (file shrank)
    public let totalBlocks: Int
    public let localMap: BlockMap

    public var hasChanges: Bool {
        !changedBlocks.isEmpty || !addedBlocks.isEmpty || !removedBlocks.isEmpty
    }

    public var changedByteCount: Int {
        (changedBlocks.count + addedBlocks.count) * localMap.blockSize
    }
}

// MARK: - DeltaSync
// Block-level diff for re-uploads — only transfer changed blocks.
// rsync-inspired rolling CRC32 comparison. 256 KB block size.

public actor DeltaSync {
    static let defaultBlockSize = 256 * 1024  // 256 KB
    private let checksumEngine = ChecksumEngine.shared
    private let resumeStore = ResumeStore.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DeltaSync")

    public init() {}

    // MARK: - Block Map Computation

    public func computeBlockMap(url: URL) async throws -> BlockMap {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()

        guard fileSize > 0 else {
            return BlockMap(fileSize: 0, blockSize: Self.defaultBlockSize, checksums: [], sha256: emptyHash, modificationDate: modDate)
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var checksums: [String] = []
        var offset: Int64 = 0

        while offset < fileSize {
            let remaining = Int(min(Int64(Self.defaultBlockSize), fileSize - offset))
            let block = try ChunkSlicer.readChunk(fileHandle: fileHandle, offset: offset, size: remaining)
            let crc = await checksumEngine.crc32c(of: block)
            checksums.append(String(format: "%08x", crc))
            offset += Int64(remaining)
        }

        let wholeSHA256 = try await checksumEngine.sha256Stream(url: url)
        return BlockMap(fileSize: fileSize, blockSize: Self.defaultBlockSize, checksums: checksums, sha256: wholeSHA256, modificationDate: modDate)
    }

    // MARK: - Diff

    public func diffBlockMaps(local: BlockMap, remote: BlockMap) -> BlockDiff {
        let localCount = local.checksums.count
        let remoteCount = remote.checksums.count
        let commonCount = min(localCount, remoteCount)

        var changed: [Int] = []
        for i in 0..<commonCount {
            if local.checksums[i] != remote.checksums[i] {
                changed.append(i)
            }
        }
        let added = localCount > remoteCount ? Array(remoteCount..<localCount) : []
        let removed = remoteCount > localCount ? Array(localCount..<remoteCount) : []

        return BlockDiff(
            changedBlocks: changed,
            addedBlocks: added,
            removedBlocks: removed,
            totalBlocks: localCount,
            localMap: local
        )
    }

    // MARK: - Eligibility Check

    /// Returns true if delta sync should be attempted for this file/provider combo.
    public func shouldUseDelta(fileSize: Int64, provider: any CloudProvider, fileURL: URL) async -> Bool {
        guard fileSize > 50 * 1024 * 1024 else { return false }  // only for files > 50 MB
        guard provider.supportsBlockManifest else { return false }
        let manifest = try? await resumeStore.loadBlockManifest(fileURL: fileURL, providerID: provider.id)
        return manifest != nil
    }

    // MARK: - Private

    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
