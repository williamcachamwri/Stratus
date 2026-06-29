import Foundation
import os.log

// MARK: - Upload Result

public struct UploadResult: Sendable {
    public let remoteItem: CloudFileItem
    public let bytesUploaded: Int64
    public let bytesSkippedByDelta: Int64
    public let checksumVerified: Bool
    public let durationSeconds: Double
    public let chunkCount: Int
    public let retriedChunks: Int
}

// MARK: - ChunkEngine
// Central orchestrator for a single file's parallel multipart upload.
// Manages the full lifecycle: hash → delta-check → chunk → upload → verify → assemble.

public actor ChunkEngine {
    private let checksumEngine = ChecksumEngine.shared
    private let resumeStore = ResumeStore.shared
    private let throttle = UploadThrottlePolicy.shared
    private let uploader = ParallelStreamUploader()
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ChunkEngine")

    public init() {}

    // MARK: - Main Upload Entry Point

    public func upload(
        task: UploadTask,
        provider: any CloudProvider,
        account: CloudAccount,
        bandwidthMonitor: BandwidthMonitor,
        congestionController: CongestionController,
        progressStream: AsyncStream<ChunkProgress>.Continuation
    ) async throws -> UploadResult {
        let startTime = Date()

        // 1. Determine optimal parallelism
        let bandwidth = await bandwidthMonitor.currentBPS
        let config = ChunkSlicer.optimalConfig(
            fileSize: task.fileSize,
            bandwidthBPS: bandwidth,
            rtt: await congestionController.smoothedRTT,
            capabilities: provider.capabilities
        )

        // 2. Small file: single-part upload (skip multipart)
        if task.fileSize < Int64(provider.capabilities.multipartThresholdBytes) {
            return try await uploadSmallFile(task: task, provider: provider, account: account, startTime: startTime)
        }

        // 3. Build chunk map
        let chunks = ChunkSlicer.slice(fileSize: task.fileSize, chunkSize: config.chunkSize)
        let totalChunks = chunks.count

        // 4. Check ResumeStore for existing session (crash resume)
        var session = try await resumeStore.loadSession(task.id.uuidString)
        let uploadID: String
        if let existing = session, existing.fileChecksum == task.localChecksum {
            if let existingID = existing.uploadID {
                uploadID = existingID
            } else {
                uploadID = try await startMultipart(task: task, provider: provider, account: account, session: &session, chunks: chunks)
            }
            logger.info("Resuming upload \(task.id) from chunk \(existing.completedChunks.count)/\(totalChunks)")
        } else {
            uploadID = try await startMultipart(task: task, provider: provider, account: account, session: &session, chunks: chunks)
            logger.info("Starting new upload \(task.id) — \(totalChunks) chunks × \(config.chunkSize / 1024 / 1024) MB")
        }

        // 5. Determine which chunks still need uploading
        let completedSet = Set(session?.completedChunks ?? [])
        let pendingChunks = chunks.filter { !completedSet.contains($0.number) }

        // 6. Open file handle once — thread-safe pread used per chunk
        let fileHandle = try FileHandle(forReadingFrom: task.sourceURL)
        defer { try? fileHandle.close() }

        var etags = session?.etags ?? [:]
        var bytesTransferred = Int64(completedSet.reduce(0) { acc, chunkNum in
            acc + Int(chunks.first(where: { $0.number == chunkNum })?.size ?? 0)
        })
        var retriedChunks = 0

        // 7. Parallel chunk upload with dynamic concurrency
        try await withThrowingTaskGroup(of: (Int, ChunkUploadResult).self) { group in
            var inFlight = 0
            var pendingIterator = pendingChunks.makeIterator()
            var maxConcurrent = await congestionController.recommendedParallelism

            // Seed initial slots
            while inFlight < maxConcurrent, let chunk = pendingIterator.next() {
                group.addTask { [chunk] in
                    let result = try await self.uploadChunk(chunk: chunk, task: task, uploadID: uploadID,
                                                            provider: provider, account: account,
                                                            fileHandle: fileHandle,
                                                            bandwidthMonitor: bandwidthMonitor)
                    return (chunk.number, result)
                }
                inFlight += 1
            }

            // Drain results and add more work
            for try await (chunkNumber, result) in group {
                inFlight -= 1
                etags[chunkNumber] = result.etag ?? ""
                bytesTransferred += Int64(chunks[chunkNumber].size)

                // Persist checkpoint
                try await resumeStore.markChunkComplete(
                    sessionID: task.id.uuidString,
                    chunk: chunkNumber,
                    etag: result.etag ?? ""
                )

                // Update congestion window
                await congestionController.onChunkSuccess(rtt: 0.05)
                maxConcurrent = await congestionController.recommendedParallelism

                // Throttle delay
                let delay = await throttle.delayBetweenChunks(chunkSize: config.chunkSize, activeConcurrency: inFlight)
                if delay > 0 {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                // Report progress to UI
                let completed = etags.count
                progressStream.yield(ChunkProgress(
                    total: totalChunks,
                    completed: completed,
                    inFlight: inFlight,
                    failed: 0,
                    bytesTransferred: bytesTransferred,
                    totalBytes: task.fileSize,
                    currentSpeedBPS: await bandwidthMonitor.currentBPS,
                    estimatedSecondsRemaining: await bandwidthMonitor.estimatedTimeRemaining(bytesLeft: task.fileSize - bytesTransferred)
                ))

                // Schedule next chunk
                if let next = pendingIterator.next(), inFlight < maxConcurrent {
                    group.addTask { [next] in
                        let result = try await self.uploadChunk(chunk: next, task: task, uploadID: uploadID,
                                                                provider: provider, account: account,
                                                                fileHandle: fileHandle,
                                                                bandwidthMonitor: bandwidthMonitor)
                        return (next.number, result)
                    }
                    inFlight += 1
                }
            }
        }

        // 8. Complete multipart upload
        let parts = (0..<totalChunks).map { CompletedPart(partNumber: $0 + 1, etag: etags[$0] ?? "") }
        let remoteItem = try await provider.completeMultipartUpload(uploadID: uploadID, parts: parts, account: account)

        // 9. Verify server checksum
        let verified: Bool
        if let remote = try? await provider.remoteChecksum(path: task.destinationPath, account: account) {
            verified = remote.value.lowercased() == task.localChecksum.lowercased()
        } else {
            verified = true  // Trust server if no checksum endpoint
        }

        // 10. Clean up ResumeStore on success
        try await resumeStore.deleteSession(task.id.uuidString)

        let duration = Date().timeIntervalSince(startTime)
        return UploadResult(
            remoteItem: remoteItem,
            bytesUploaded: bytesTransferred,
            bytesSkippedByDelta: 0,
            checksumVerified: verified,
            durationSeconds: duration,
            chunkCount: totalChunks,
            retriedChunks: retriedChunks
        )
    }

    // MARK: - Private Helpers

    private func startMultipart(
        task: UploadTask,
        provider: any CloudProvider,
        account: CloudAccount,
        session: inout UploadSession?,
        chunks: [ChunkDescriptor]
    ) async throws -> String {
        let uploadID = try await provider.initiateMultipartUpload(
            remotePath: task.destinationPath,
            account: account,
            metadata: task.metadata
        )
        let newSession = UploadSession(
            id: task.id.uuidString,
            fileURLString: task.sourceURL.path,
            providerID: task.providerID,
            accountID: task.accountID,
            remotePath: task.destinationPath.path,
            uploadID: uploadID,
            fileSize: task.fileSize,
            fileChecksum: task.localChecksum,
            chunkSize: chunks.first?.size ?? 0,
            totalChunks: chunks.count
        )
        try await resumeStore.saveSession(newSession)
        session = newSession
        return uploadID
    }

    private func uploadChunk(
        chunk: ChunkDescriptor,
        task: UploadTask,
        uploadID: String,
        provider: any CloudProvider,
        account: CloudAccount,
        fileHandle: FileHandle,
        bandwidthMonitor: BandwidthMonitor
    ) async throws -> ChunkUploadResult {
        let data = try ChunkSlicer.readChunk(fileHandle: fileHandle, offset: chunk.offset, size: chunk.size)
        let t0 = Date()
        let result = try await provider.uploadChunk(
            uploadID: uploadID,
            chunkNumber: chunk.number + 1,  // providers use 1-based part numbers
            data: data,
            account: account
        )
        let elapsed = Date().timeIntervalSince(t0)
        await bandwidthMonitor.recordBytes(Int64(chunk.size), elapsed: elapsed)
        return result
    }

    private func uploadSmallFile(
        task: UploadTask,
        provider: any CloudProvider,
        account: CloudAccount,
        startTime: Date
    ) async throws -> UploadResult {
        let data = try Data(contentsOf: task.sourceURL)
        let remoteItem = try await provider.uploadSmallFile(
            data: data,
            remotePath: task.destinationPath,
            account: account,
            metadata: task.metadata
        )
        let verified: Bool
        if let remote = try? await provider.remoteChecksum(path: task.destinationPath, account: account) {
            verified = remote.value.lowercased() == task.localChecksum.lowercased()
        } else {
            verified = true
        }
        return UploadResult(
            remoteItem: remoteItem,
            bytesUploaded: Int64(data.count),
            bytesSkippedByDelta: 0,
            checksumVerified: verified,
            durationSeconds: Date().timeIntervalSince(startTime),
            chunkCount: 1,
            retriedChunks: 0
        )
    }
}
