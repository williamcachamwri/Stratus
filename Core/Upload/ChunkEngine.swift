import Foundation
import CryptoKit
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

private struct ChunkOutcome: Sendable {
    let chunkNumber: Int
    let etag: String
    let retries: Int
    let plaintextBytes: Int64
    let wireBytes: Int64
    let checksumVerified: Bool
}

// MARK: - ChunkEngine
// Central orchestrator for a single file's upload lifecycle.

public actor ChunkEngine {
    private let checksumEngine = ChecksumEngine.shared
    private let resumeStore = ResumeStore.shared
    private let deltaSync = DeltaSync()
    private let throttle = UploadThrottlePolicy.shared
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
        let encryptionPipeline = try await makeEncryptionPipelineIfNeeded(task: task, account: account)
        let isEncryptedUpload = encryptionPipeline != nil

        var deltaMapToStore: BlockMap?
        var bytesSkippedByDelta: Int64 = 0
        if !isEncryptedUpload {
            switch try await deltaSync.planUpload(
                fileURL: task.sourceURL,
                remotePath: task.destinationPath,
                account: account,
                provider: provider
            ) {
            case .skip(_, let bytesSkipped):
                bytesSkippedByDelta = bytesSkipped
                let remoteItem = (try? await provider.fileMetadata(path: task.destinationPath, account: account))
                    ?? CloudFileItem(id: task.destinationPath.path, name: task.destinationPath.lastComponent, path: task.destinationPath, size: task.fileSize)
                return UploadResult(
                    remoteItem: remoteItem,
                    bytesUploaded: 0,
                    bytesSkippedByDelta: bytesSkippedByDelta,
                    checksumVerified: true,
                    durationSeconds: Date().timeIntervalSince(startTime),
                    chunkCount: 0,
                    retriedChunks: 0
                )
            case .uploadFull(let localMap, _, let reason):
                deltaMapToStore = localMap
                logger.info("Delta full-upload fallback for \(task.destinationPath.path, privacy: .private): \(reason, privacy: .public)")
            case .unavailable(let reason):
                logger.debug("Delta unavailable for \(task.destinationPath.path, privacy: .private): \(reason, privacy: .public)")
            }
        } else {
            logger.debug("Delta sync disabled for encrypted upload \(task.destinationPath.path, privacy: .private) to avoid plaintext manifest leakage")
        }

        let bandwidth = await bandwidthMonitor.currentBPS
        let config = ChunkSlicer.optimalConfig(
            fileSize: task.fileSize,
            bandwidthBPS: bandwidth,
            rtt: await congestionController.smoothedRTT,
            capabilities: provider.capabilities
        )

        if !provider.capabilities.supportsMultipartUpload || task.fileSize < Int64(provider.capabilities.multipartThresholdBytes) {
            return try await uploadSmallFile(
                task: task,
                provider: provider,
                account: account,
                encryptionPipeline: encryptionPipeline,
                deltaMapToStore: deltaMapToStore,
                startTime: startTime
            )
        }

        let chunks = ChunkSlicer.slice(fileSize: task.fileSize, chunkSize: config.chunkSize)
        let totalChunks = chunks.count

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

        let completedSet = Set(session?.completedChunks ?? [])
        let pendingChunks = chunks.filter { !completedSet.contains($0.number) }
        let fileHandle = try FileHandle(forReadingFrom: task.sourceURL)
        defer { try? fileHandle.close() }

        var etags = session?.etags ?? [:]
        var plaintextTransferred = Int64(completedSet.reduce(0) { acc, chunkNum in
            acc + Int(chunks.first(where: { $0.number == chunkNum })?.size ?? 0)
        })
        var wireBytesUploaded: Int64 = plaintextTransferred
        var retriedChunks = 0
        var failedChunks = 0
        var chunkVerification = true

        do {
            try await withThrowingTaskGroup(of: ChunkOutcome.self) { group in
                var inFlight = 0
                var pendingIterator = pendingChunks.makeIterator()
                var maxConcurrent = await effectiveChunkConcurrency(
                    config: config,
                    provider: provider,
                    congestionController: congestionController
                )

                while inFlight < maxConcurrent, let chunk = pendingIterator.next() {
                    try Task.checkCancellation()
                    group.addTask { [chunk] in
                        try await self.uploadChunk(
                            chunk: chunk,
                            uploadID: uploadID,
                            provider: provider,
                            account: account,
                            fileHandle: fileHandle,
                            encryptionPipeline: encryptionPipeline,
                            bandwidthMonitor: bandwidthMonitor,
                            congestionController: congestionController
                        )
                    }
                    inFlight += 1
                }

                for try await outcome in group {
                    try Task.checkCancellation()
                    inFlight -= 1
                    retriedChunks += outcome.retries
                    etags[outcome.chunkNumber] = outcome.etag
                    plaintextTransferred += outcome.plaintextBytes
                    wireBytesUploaded += outcome.wireBytes
                    chunkVerification = chunkVerification && outcome.checksumVerified

                    try await resumeStore.markChunkComplete(
                        sessionID: task.id.uuidString,
                        chunk: outcome.chunkNumber,
                        etag: outcome.etag
                    )

                    await congestionController.onChunkSuccess(rtt: 0.05)
                    maxConcurrent = await effectiveChunkConcurrency(
                        config: config,
                        provider: provider,
                        congestionController: congestionController
                    )

                    let delay = await throttle.delayBetweenChunks(chunkSize: config.chunkSize, activeConcurrency: inFlight)
                    if delay > 0 {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }

                    progressStream.yield(ChunkProgress(
                        total: totalChunks,
                        completed: etags.count,
                        inFlight: inFlight,
                        failed: failedChunks,
                        bytesTransferred: plaintextTransferred,
                        totalBytes: task.fileSize,
                        currentSpeedBPS: await bandwidthMonitor.currentBPS,
                        estimatedSecondsRemaining: await bandwidthMonitor.estimatedTimeRemaining(bytesLeft: max(0, task.fileSize - plaintextTransferred))
                    ))

                    if let next = pendingIterator.next(), inFlight < maxConcurrent {
                        group.addTask { [next] in
                            try await self.uploadChunk(
                                chunk: next,
                                uploadID: uploadID,
                                provider: provider,
                                account: account,
                                fileHandle: fileHandle,
                                encryptionPipeline: encryptionPipeline,
                                bandwidthMonitor: bandwidthMonitor,
                                congestionController: congestionController
                            )
                        }
                        inFlight += 1
                    }
                }
            }
        } catch is CancellationError {
            try? await resumeStore.updateSessionState(task.id.uuidString, state: "paused", error: nil)
            throw UploadError.cancelled
        } catch {
            failedChunks += 1
            try? await resumeStore.updateSessionState(task.id.uuidString, state: "failed", error: String(describing: error))
            try? await provider.abortMultipartUpload(uploadID: uploadID, account: account)
            throw error
        }

        let parts = try (0..<totalChunks).map { chunkNumber -> CompletedPart in
            guard let etag = etags[chunkNumber], !etag.isEmpty else {
                throw UploadError.providerError("Missing ETag for completed chunk \(chunkNumber + 1)")
            }
            return CompletedPart(partNumber: chunkNumber + 1, etag: etag)
        }
        let remoteItem = try await provider.completeMultipartUpload(uploadID: uploadID, parts: parts, account: account)

        guard chunkVerification else {
            throw UploadError.providerError("Provider did not confirm one or more chunk checksums")
        }

        let finalChecksumVerified: Bool
        if isEncryptedUpload {
            finalChecksumVerified = chunkVerification
        } else {
            finalChecksumVerified = try await verifyFinalChecksum(
                provider: provider,
                account: account,
                path: task.destinationPath,
                expectedSHA256: task.localChecksum,
                expectedMD5: try await checksumEngine.md5Stream(url: task.sourceURL),
                fallbackConfirmed: chunkVerification
            )
        }

        if !isEncryptedUpload, let deltaMapToStore {
            try? await provider.storeBlockManifest(deltaMapToStore, path: task.destinationPath, account: account)
            try? await resumeStore.saveBlockManifest(deltaMapToStore, fileURL: task.sourceURL, providerID: provider.id, accountID: account.id, remotePath: task.destinationPath.path)
        }

        try await resumeStore.deleteSession(task.id.uuidString)
        return UploadResult(
            remoteItem: remoteItem,
            bytesUploaded: wireBytesUploaded,
            bytesSkippedByDelta: bytesSkippedByDelta,
            checksumVerified: finalChecksumVerified,
            durationSeconds: Date().timeIntervalSince(startTime),
            chunkCount: totalChunks,
            retriedChunks: retriedChunks
        )
    }

    // MARK: - Private Helpers

    private func effectiveChunkConcurrency(
        config: ParallelismConfig,
        provider: any CloudProvider,
        congestionController: CongestionController
    ) async -> Int {
        let providerLimit = max(1, provider.capabilities.maxConcurrentUploads)
        let congestionLimit = max(1, await congestionController.recommendedParallelism)
        let configLimit = max(1, config.maxConcurrentChunks)
        return max(1, min(providerLimit, congestionLimit, configLimit))
    }

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
        task.setUploadID(uploadID)
        let newSession = UploadSession(
            id: task.id.uuidString,
            fileBookmark: try ResumeStore.makeBookmarkData(for: task.sourceURL),
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
        uploadID: String,
        provider: any CloudProvider,
        account: CloudAccount,
        fileHandle: FileHandle,
        encryptionPipeline: EncryptedChunkPipeline?,
        bandwidthMonitor: BandwidthMonitor,
        congestionController: CongestionController
    ) async throws -> ChunkOutcome {
        try Task.checkCancellation()
        let plaintext = try ChunkSlicer.readChunk(fileHandle: fileHandle, offset: chunk.offset, size: chunk.size)
        let payload: Data
        let expectedChecksum: String
        if let encryptionPipeline {
            let processed = try await encryptionPipeline.processChunk(
                data: plaintext,
                chunkIndex: chunk.number,
                fileID: uploadID
            )
            payload = processed.encryptedData
            expectedChecksum = processed.encryptedChecksum
        } else {
            payload = plaintext
            expectedChecksum = await checksumEngine.sha256(of: payload)
        }

        let maxAttempts = 6
        var attempt = 1
        var retries = 0

        while true {
            try Task.checkCancellation()
            let t0 = Date()
            do {
                let result = try await provider.uploadChunk(
                    uploadID: uploadID,
                    chunkNumber: chunk.number + 1,
                    data: payload,
                    account: account
                )
                let elapsed = Date().timeIntervalSince(t0)
                await bandwidthMonitor.recordBytes(Int64(payload.count), elapsed: elapsed)
                let checksumVerified = try verifyChunkChecksum(result: result, expectedSHA256: expectedChecksum)
                return ChunkOutcome(
                    chunkNumber: chunk.number,
                    etag: result.etag ?? "",
                    retries: retries,
                    plaintextBytes: Int64(plaintext.count),
                    wireBytes: Int64(payload.count),
                    checksumVerified: checksumVerified
                )
            } catch {
                if !isRetriable(error) || attempt >= maxAttempts {
                    await congestionController.onChunkError()
                    throw UploadError.chunkExhausted(chunkNumber: chunk.number + 1, attempts: attempt)
                }

                retries += 1
                attempt += 1
                if case ProviderError.rateLimited(let retryAfter) = error {
                    await congestionController.onChunkRateLimited(retryAfter: retryAfter)
                    try await Task.sleep(nanoseconds: UInt64(max(0, retryAfter) * 1_000_000_000))
                } else {
                    await congestionController.onChunkTimeout()
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds(forAttempt: attempt))
                }
            }
        }
    }

    private func uploadSmallFile(
        task: UploadTask,
        provider: any CloudProvider,
        account: CloudAccount,
        encryptionPipeline: EncryptedChunkPipeline?,
        deltaMapToStore: BlockMap?,
        startTime: Date
    ) async throws -> UploadResult {
        let plaintext = try Data(contentsOf: task.sourceURL)
        let payload: Data
        let expectedSHA256: String
        let expectedMD5: String
        if let encryptionPipeline {
            let processed = try await encryptionPipeline.processChunk(data: plaintext, chunkIndex: 0, fileID: task.id.uuidString)
            payload = processed.encryptedData
            expectedSHA256 = processed.encryptedChecksum
            expectedMD5 = await checksumEngine.md5(of: payload)
        } else {
            payload = plaintext
            expectedSHA256 = task.localChecksum
            expectedMD5 = await checksumEngine.md5(of: payload)
        }

        let remoteItem = try await provider.uploadSmallFile(
            data: payload,
            remotePath: task.destinationPath,
            account: account,
            metadata: task.metadata
        )
        let verified = try await verifyFinalChecksum(
            provider: provider,
            account: account,
            path: task.destinationPath,
            expectedSHA256: expectedSHA256,
            expectedMD5: expectedMD5,
            fallbackConfirmed: false
        )
        guard verified else {
            throw UploadError.providerError("Provider did not expose a verifiable checksum for small-file upload")
        }

        if encryptionPipeline == nil, let deltaMapToStore {
            try? await provider.storeBlockManifest(deltaMapToStore, path: task.destinationPath, account: account)
            try? await resumeStore.saveBlockManifest(deltaMapToStore, fileURL: task.sourceURL, providerID: provider.id, accountID: account.id, remotePath: task.destinationPath.path)
        }

        return UploadResult(
            remoteItem: remoteItem,
            bytesUploaded: Int64(payload.count),
            bytesSkippedByDelta: 0,
            checksumVerified: true,
            durationSeconds: Date().timeIntervalSince(startTime),
            chunkCount: 1,
            retriedChunks: 0
        )
    }

    private func makeEncryptionPipelineIfNeeded(task: UploadTask, account: CloudAccount) async throws -> EncryptedChunkPipeline? {
        guard encryptionEnabled(in: task.metadata) else { return nil }
        guard let vaultID = task.metadata.customAttributes["stratus.encryption.vaultID"], !vaultID.isEmpty else {
            throw UploadError.providerError("Encrypted upload requested but no vault ID was provided")
        }
        guard let keyData = try await KeychainStore.shared.loadSecret(
            service: KeychainStore.ServiceName.encryptionKey(vaultID: vaultID),
            account: account.id
        ) else {
            throw UploadError.providerError("Encrypted upload requested but vault key \(vaultID) is missing from Keychain")
        }
        guard keyData.count == 32 else {
            throw UploadError.providerError("Vault key \(vaultID) must be exactly 32 bytes for AES-256-GCM")
        }
        let encryption = ClientSideEncryption(masterKey: SymmetricKey(data: keyData))
        return EncryptedChunkPipeline(encryption: encryption, checksumEngine: checksumEngine)
    }

    private func encryptionEnabled(in metadata: UploadMetadata) -> Bool {
        let value = metadata.customAttributes["stratus.encryption.enabled"]?.lowercased()
            ?? metadata.customAttributes["encryption"]?.lowercased()
            ?? "false"
        return ["1", "true", "yes", "client", "client-side"].contains(value)
    }

    private func verifyChunkChecksum(result: ChunkUploadResult, expectedSHA256: String) throws -> Bool {
        if let checksum = result.checksum?.trimmingCharacters(in: .whitespacesAndNewlines), !checksum.isEmpty {
            guard checksum.lowercased() == expectedSHA256.lowercased() else {
                throw ProviderError.checksumMismatch(expected: expectedSHA256, actual: checksum)
            }
            return true
        }
        return result.serverConfirmedChecksum
    }

    private func verifyFinalChecksum(
        provider: any CloudProvider,
        account: CloudAccount,
        path: CloudPath,
        expectedSHA256: String,
        expectedMD5: String,
        fallbackConfirmed: Bool
    ) async throws -> Bool {
        if let remote = try await provider.remoteChecksum(path: path, account: account) {
            switch remote.algorithm {
            case .sha256:
                guard remote.value.lowercased() == expectedSHA256.lowercased() else {
                    throw UploadError.checksumMismatch(expected: expectedSHA256, actual: remote.value)
                }
                return true
            case .md5:
                guard remote.value.lowercased() == expectedMD5.lowercased() else {
                    throw UploadError.checksumMismatch(expected: expectedMD5, actual: remote.value)
                }
                return true
            case .sha1, .crc32c:
                return fallbackConfirmed
            }
        }
        return fallbackConfirmed
    }

    private func isRetriable(_ error: Error) -> Bool {
        switch error {
        case ProviderError.rateLimited, ProviderError.networkUnavailable:
            return true
        case ProviderError.serverError(let statusCode, _):
            return [408, 429, 500, 502, 503, 504].contains(statusCode)
        case ProviderError.accessDenied(_), ProviderError.authenticationFailed(_), ProviderError.fileNotFound(_),
             ProviderError.quotaExceeded, ProviderError.sessionExpired, ProviderError.unsupportedOperation(_),
             ProviderError.checksumMismatch(_, _), ProviderError.invalidResponse(_), ProviderError.providerSpecific(_, _):
            return false
        default:
            return true
        }
    }

    private func retryDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let retryIndex = max(0, attempt - 2)
        let base = min(pow(2.0, Double(retryIndex)), 16.0)
        let jitter = Double.random(in: -0.25...0.25) * base
        return UInt64(max(0.25, base + jitter) * 1_000_000_000)
    }
}
