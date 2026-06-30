import Foundation
import os.log

// MARK: - Block Diff

public struct BlockDiff: Sendable {
    public let changedBlocks: [Int]
    public let addedBlocks: [Int]
    public let removedBlocks: [Int]
    public let totalBlocks: Int
    public let localMap: BlockMap

    public var hasChanges: Bool {
        !changedBlocks.isEmpty || !addedBlocks.isEmpty || !removedBlocks.isEmpty
    }

    public var changedByteCount: Int64 {
        Int64(changedBlocks.count + addedBlocks.count) * Int64(localMap.blockSize)
    }
}

public enum DeltaUploadPlan: Sendable {
    case unavailable(reason: String)
    case skip(localMap: BlockMap, bytesSkipped: Int64)
    case uploadFull(localMap: BlockMap, diff: BlockDiff?, reason: String)
}

// MARK: - DeltaSync

// Block-level diff planner.  Providers in the current protocol cannot patch
// arbitrary object byte ranges safely, so this actor only performs true delta
// skips when the remote manifest proves the file is unchanged.  Changed blocks
// intentionally fall back to full upload instead of pretending bytes were saved.

public actor DeltaSync {
    static let defaultBlockSize = 256 * 1024
    private let checksumEngine = ChecksumEngine.shared
    private let resumeStore = ResumeStore.shared
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "DeltaSync")

    public init() {}

    // MARK: - Planning

    public func planUpload(
        fileURL: URL,
        remotePath: CloudPath,
        account: CloudAccount,
        provider: any CloudProvider
    ) async throws -> DeltaUploadPlan {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        guard fileSize > 50 * 1024 * 1024 else {
            return .unavailable(
                reason: "Files smaller than 50 MB use normal upload because block manifests cost more than they save."
            )
        }
        guard provider.supportsBlockManifest else {
            return .unavailable(reason: "Provider does not support Stratus block manifests.")
        }

        let localMap = try await computeBlockMap(url: fileURL)
        let providerMap = try await provider.fetchBlockManifest(path: remotePath, account: account)
        let localCachedMap = try await resumeStore.loadBlockManifest(fileURL: fileURL, providerID: provider.id)
        let remoteMap = providerMap ?? localCachedMap

        guard let remoteMap else {
            return .uploadFull(
                localMap: localMap,
                diff: nil,
                reason: "No previous block manifest exists for this object."
            )
        }

        if localMap.sha256 == remoteMap.sha256, localMap.fileSize == remoteMap.fileSize {
            logger.info("Delta skip: local SHA-256 matches remote manifest for \(remotePath.path, privacy: .private)")
            return .skip(localMap: localMap, bytesSkipped: localMap.fileSize)
        }

        let diff = diffBlockMaps(local: localMap, remote: remoteMap)
        if !diff.hasChanges {
            return .skip(localMap: localMap, bytesSkipped: localMap.fileSize)
        }

        return .uploadFull(
            localMap: localMap,
            diff: diff,
            reason: "Provider protocol cannot safely patch changed byte ranges yet; falling back to full upload."
        )
    }

    // MARK: - Block Map Computation

    public func computeBlockMap(url: URL) async throws -> BlockMap {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date()

        guard fileSize > 0 else {
            return BlockMap(
                fileSize: 0,
                blockSize: Self.defaultBlockSize,
                checksums: [],
                sha256: emptyHash,
                modificationDate: modDate
            )
        }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var checksums: [String] = []
        var offset: Int64 = 0

        while offset < fileSize {
            try Task.checkCancellation()
            let remaining = Int(min(Int64(Self.defaultBlockSize), fileSize - offset))
            let block = try ChunkSlicer.readChunk(fileHandle: fileHandle, offset: offset, size: remaining)
            let crc = await checksumEngine.crc32c(of: block)
            checksums.append(String(format: "%08x", crc))
            offset += Int64(remaining)
        }

        let wholeSHA256 = try await checksumEngine.sha256Stream(url: url)
        return BlockMap(
            fileSize: fileSize,
            blockSize: Self.defaultBlockSize,
            checksums: checksums,
            sha256: wholeSHA256,
            modificationDate: modDate
        )
    }

    // MARK: - Diff

    public func diffBlockMaps(local: BlockMap, remote: BlockMap) -> BlockDiff {
        let localCount = local.checksums.count
        let remoteCount = remote.checksums.count
        let commonCount = min(localCount, remoteCount)

        var changed: [Int] = []
        for i in 0 ..< commonCount {
            if local.checksums[i] != remote.checksums[i] {
                changed.append(i)
            }
        }
        let added = localCount > remoteCount ? Array(remoteCount ..< localCount) : []
        let removed = remoteCount > localCount ? Array(localCount ..< remoteCount) : []

        return BlockDiff(
            changedBlocks: changed,
            addedBlocks: added,
            removedBlocks: removed,
            totalBlocks: localCount,
            localMap: local
        )
    }

    // MARK: - Eligibility Check

    public func shouldUseDelta(fileSize: Int64, provider: any CloudProvider, fileURL: URL) async -> Bool {
        guard fileSize > 50 * 1024 * 1024 else { return false }
        guard provider.supportsBlockManifest else { return false }
        let manifest = try? await resumeStore.loadBlockManifest(fileURL: fileURL, providerID: provider.id)
        return manifest != nil
    }

    // MARK: - Private

    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
}
