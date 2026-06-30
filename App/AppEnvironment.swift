import os.log
import StratusCore
import SwiftUI

// MARK: - Upload Dashboard Presentation State

public enum UploadDisplayPhase: String, Sendable, CaseIterable {
    case queued
    case hashing
    case uploading
    case paused
    case failed
    case completed
    case cancelled
    case skipped
}

public struct UploadRowState: Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let providerID: String
    public let destinationPath: String
    public let phase: UploadDisplayPhase
    public let progress: Double
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let speedBPS: Double
    public let etaSeconds: Double?
    public let chunkText: String?
    public let detailText: String
    public let checksumVerified: Bool
    public let updatedAt: Date
}

public struct UploadDashboardSummary: Sendable {
    public let activeCount: Int
    public let queuedCount: Int
    public let failedCount: Int
    public let pausedCount: Int
    public let completedCount: Int
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let currentBPS: Double
    public let peakBPS: Double
    public let etaSeconds: Double?

    public static let empty = UploadDashboardSummary(
        activeCount: 0,
        queuedCount: 0,
        failedCount: 0,
        pausedCount: 0,
        completedCount: 0,
        bytesTransferred: 0,
        totalBytes: 0,
        currentBPS: 0,
        peakBPS: 0,
        etaSeconds: nil
    )

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesTransferred) / Double(totalBytes))
    }
}

// MARK: - Download Dashboard Presentation State

public enum DownloadDisplayPhase: String, Sendable, CaseIterable {
    case queued
    case downloading
    case paused
    case failed
    case completed
    case cancelled
    case restored
}

public struct DownloadRowState: Identifiable, Sendable {
    public let id: UUID
    public let fileName: String
    public let providerID: String
    public let sourcePath: String
    public let destinationPath: String
    public let phase: DownloadDisplayPhase
    public let progress: Double
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let speedBPS: Double
    public let etaSeconds: Double?
    public let rangeText: String
    public let detailText: String
    public let checksumVerified: Bool
    public let updatedAt: Date
}

public struct DownloadDashboardSummary: Sendable {
    public let activeCount: Int
    public let queuedCount: Int
    public let failedCount: Int
    public let pausedCount: Int
    public let completedCount: Int
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let currentBPS: Double
    public let etaSeconds: Double?

    public static let empty = DownloadDashboardSummary(
        activeCount: 0,
        queuedCount: 0,
        failedCount: 0,
        pausedCount: 0,
        completedCount: 0,
        bytesReceived: 0,
        totalBytes: 0,
        currentBPS: 0,
        etaSeconds: nil
    )

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(totalBytes))
    }
}

// MARK: - AppEnvironment

// Single source of truth for real app state and services injected into SwiftUI.

@MainActor
public final class AppEnvironment: ObservableObject {
    public static let shared = AppEnvironment()

    // MARK: - Services

    let uploadEngine = UploadEngine.shared
    let downloadEngine = DownloadEngine.shared
    let syncEngine = SyncEngine.shared
    let syncScheduler = SyncScheduler.shared
    let providerRegistry = CloudProviderRegistry.shared
    let appUpdater = AppUpdater.shared
    let vfsMount = VFSMount.shared

    private let accountStore = AccountStore.shared
    private let providerConfigStore = ProviderAccountConfigStore.shared
    private let credentialVault = CredentialVault.shared

    // MARK: - Observable State

    @Published public var accounts: [CloudAccount] = []
    @Published public var activeSyncPairs: [SyncPair] = []
    @Published public var pendingConflicts: [SyncConflict] = []
    @Published public var uploadEvents: [UploadEngineEvent] = []
    @Published public var uploadRows: [UploadRowState] = []
    @Published public var uploadSummary: UploadDashboardSummary = .empty
    @Published public var uploadBandwidthSnapshot: BWSnapshot?
    @Published public var uploadSpeedHistory: [Double] = []
    @Published public var downloadRows: [DownloadRowState] = []
    @Published public var downloadSummary: DownloadDashboardSummary = .empty
    @Published public var isOnline: Bool = true
    @Published public var activeUploads: Int = 0
    @Published public var mountRows: [MountRow] = []

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "AppEnvironment")
    private var uploadEventTask: Task<Void, Never>?
    private var uploadBandwidthTask: Task<Void, Never>?
    private var downloadEventTask: Task<Void, Never>?
    private var syncEventTask: Task<Void, Never>?
    private var uploadRowStore: [UUID: UploadRowState] = [:]
    private var downloadRowStore: [UUID: DownloadRowState] = [:]

    private init() {
        startListeningForEvents()
        Task { @MainActor [weak self] in
            await self?.bootstrapRuntimeState()
        }
    }

    // MARK: - Bootstrap

    private func bootstrapRuntimeState() async {
        await loadPersistedAccounts()
        await uploadEngine.start()
        await downloadEngine.start()
        await syncScheduler.onAppLaunch()
    }

    private func loadPersistedAccounts() async {
        do {
            let persistedAccounts = try await accountStore.loadAll()
            accounts = persistedAccounts
            for account in persistedAccounts {
                let config = try await providerConfigStore.load(accountID: account.id)
                await registerProvider(for: account, config: config)
            }
            await vfsMount.reloadMountedDomains(accounts: persistedAccounts)
            await refreshMountRows()
        } catch {
            logger.error("Failed to load persisted accounts: \(error.localizedDescription)")
        }
    }

    // MARK: - Event Listeners

    private static func emptyStream<Element>() -> AsyncStream<Element> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    private func startListeningForEvents() {
        uploadEventTask = Task { @MainActor [weak self] in
            for await event in await self?.uploadEngine.events ?? Self.emptyStream() {
                self?.handleUploadEvent(event)
            }
        }

        uploadBandwidthTask = Task { @MainActor [weak self] in
            for await snapshot in await self?.uploadEngine.bandwidthUpdates ?? Self.emptyStream() {
                self?.uploadBandwidthSnapshot = snapshot
                self?.recordUploadSpeed(snapshot.currentBPS)
                self?.publishUploadState()
            }
        }

        downloadEventTask = Task { @MainActor [weak self] in
            for await event in await self?.downloadEngine.events ?? Self.emptyStream() {
                self?.handleDownloadEvent(event)
            }
        }

        syncEventTask = Task { @MainActor [weak self] in
            for await event in await self?.syncEngine.events ?? Self.emptyStream() {
                self?.handleSyncEvent(event)
            }
        }

        Task { @MainActor [weak self] in
            let reachability = NetworkReachability.shared
            for await isConnected in await reachability.statusStream {
                self?.isOnline = isConnected
            }
        }
    }

    private func handleUploadEvent(_ event: UploadEngineEvent) {
        uploadEvents.append(event)
        if uploadEvents.count > 200 { uploadEvents.removeFirst() }

        switch event {
        case let .taskAdded(task):
            uploadRowStore[task.id] = row(
                for: task,
                phase: .queued,
                detail: "Queued at scheduler priority \(task.priority.rawValue)"
            )
        case let .taskStarted(id):
            updateUploadRow(id: id, phase: .hashing, detail: "Preparing checksum, delta check, and upload session")
        case let .taskProgress(id, progress):
            updateUploadRow(id: id, progress: progress)
        case let .taskCompleted(task, result):
            uploadRowStore[task.id] = row(
                for: task,
                phase: .completed,
                progress: 1,
                bytesTransferred: result.bytesUploaded,
                speedBPS: result.durationSeconds > 0 ? Double(result.bytesUploaded) / result.durationSeconds : 0,
                etaSeconds: nil,
                chunkText: "\(result.chunkCount) chunks · \(result.retriedChunks) retries",
                detail: result.checksumVerified ? "SHA-256 verified" : "Uploaded; checksum unavailable",
                checksumVerified: result.checksumVerified
            )
            StratusNotificationCenter.shared.notifyUploadComplete(
                fileName: task.sourceURL.lastPathComponent,
                providerName: providerName(for: task.providerID)
            )
        case let .taskFailed(task, error):
            uploadRowStore[task.id] = row(
                for: task,
                phase: .failed,
                detail: error.localizedDescription,
                checksumVerified: false
            )
            StratusNotificationCenter.shared.notifyUploadFailed(
                fileName: task.sourceURL.lastPathComponent,
                error: error.localizedDescription
            )
        case let .taskPaused(id):
            updateUploadRow(id: id, phase: .paused, detail: "Paused with resume state preserved")
        case let .taskResumed(id):
            updateUploadRow(id: id, phase: .queued, detail: "Queued for resume")
        case let .taskReprioritized(id, priority):
            updateUploadRow(id: id, phase: .queued, detail: "Queued at scheduler priority \(priority.rawValue)")
        case let .taskCancelled(id):
            updateUploadRow(id: id, phase: .cancelled, detail: "Cancelled by user")
        case let .sessionRestored(count):
            logger.info("Upload engine restored \(count) persisted sessions")
        }

        publishUploadState()
        DockProgressManager.shared.updateUploadProgress(uploadSummary.progress, activeCount: activeUploads)
    }

    private func handleDownloadEvent(_ event: DownloadEngineEvent) {
        switch event {
        case let .taskAdded(task):
            downloadRowStore[task.id] = row(
                for: task,
                phase: .queued,
                detail: "Queued at priority \(task.priority.rawValue)"
            )
        case let .taskStarted(id):
            updateDownloadRow(id: id, phase: .downloading, detail: "Resolving metadata and allocating range slots")
        case let .taskProgress(id, progress):
            updateDownloadRow(id: id, progress: progress)
        case let .taskCompleted(id, summary):
            updateDownloadRow(id: id, summary: summary)
        case let .taskFailed(id, error):
            updateDownloadRow(id: id, phase: .failed, detail: error.localizedDescription)
        case let .taskPaused(id, token):
            let offset = token.map { formatBytes($0.resumeOffset) } ?? "0 B"
            updateDownloadRow(id: id, phase: .paused, detail: "Paused at \(offset)")
        case let .taskResumed(id):
            updateDownloadRow(id: id, phase: .queued, detail: "Queued for resume")
        case let .taskCancelled(id):
            updateDownloadRow(id: id, phase: .cancelled, detail: "Cancelled by user")
        case let .sessionsRestored(count):
            logger.info("Download engine restored \(count) persisted sessions")
        }
        publishDownloadState()
    }

    private func handleSyncEvent(_ event: SyncEngineEvent) {
        if case let .conflictDetected(conflict) = event {
            pendingConflicts.append(conflict)
            StratusNotificationCenter.shared.notifySyncConflict(
                fileName: conflict.localURL.lastPathComponent,
                pairID: conflict.pairID
            )
            DockProgressManager.shared.updateConflictBadge(pendingConflicts.count)
        }
        if case let .conflictResolved(conflict, _) = event {
            pendingConflicts.removeAll { $0.id == conflict.id }
            DockProgressManager.shared.updateConflictBadge(pendingConflicts.count)
        }
        if case let .syncCompleted(_, up, down, _) = event {
            StratusNotificationCenter.shared.notifySyncComplete(
                pairName: "Stratus", uploaded: up, downloaded: down
            )
        }
    }

    // MARK: - Upload Rows

    private func row(
        for task: UploadTask,
        phase: UploadDisplayPhase,
        progress: Double = 0,
        bytesTransferred: Int64 = 0,
        speedBPS: Double = 0,
        etaSeconds: Double? = nil,
        chunkText: String? = nil,
        detail: String,
        checksumVerified: Bool = false
    ) -> UploadRowState {
        UploadRowState(
            id: task.id,
            fileName: task.sourceURL.lastPathComponent,
            providerID: task.providerID,
            destinationPath: task.destinationPath.path,
            phase: phase,
            progress: progress,
            bytesTransferred: bytesTransferred,
            totalBytes: task.fileSize,
            speedBPS: speedBPS,
            etaSeconds: etaSeconds,
            chunkText: chunkText,
            detailText: detail,
            checksumVerified: checksumVerified,
            updatedAt: Date()
        )
    }

    private func updateUploadRow(id: UUID, phase: UploadDisplayPhase, detail: String) {
        guard let existing = uploadRowStore[id] else { return }
        uploadRowStore[id] = UploadRowState(
            id: existing.id,
            fileName: existing.fileName,
            providerID: existing.providerID,
            destinationPath: existing.destinationPath,
            phase: phase,
            progress: existing.progress,
            bytesTransferred: existing.bytesTransferred,
            totalBytes: existing.totalBytes,
            speedBPS: existing.speedBPS,
            etaSeconds: existing.etaSeconds,
            chunkText: existing.chunkText,
            detailText: detail,
            checksumVerified: existing.checksumVerified,
            updatedAt: Date()
        )
    }

    private func updateUploadRow(id: UUID, progress: ChunkProgress) {
        guard let existing = uploadRowStore[id] else { return }
        uploadRowStore[id] = UploadRowState(
            id: existing.id,
            fileName: existing.fileName,
            providerID: existing.providerID,
            destinationPath: existing.destinationPath,
            phase: .uploading,
            progress: progress.percentComplete,
            bytesTransferred: progress.bytesTransferred,
            totalBytes: progress.totalBytes,
            speedBPS: progress.currentSpeedBPS,
            etaSeconds: progress.estimatedSecondsRemaining.isFinite ? progress.estimatedSecondsRemaining : nil,
            chunkText: "Chunk \(progress.completed)/\(progress.total) · \(progress.inFlight) in flight",
            detailText: "\(progress.failed) failed chunks · live transfer",
            checksumVerified: existing.checksumVerified,
            updatedAt: Date()
        )
    }

    private func recordUploadSpeed(_ bps: Double) {
        uploadSpeedHistory.append(max(0, bps))
        if uploadSpeedHistory.count > 240 {
            uploadSpeedHistory.removeFirst(uploadSpeedHistory.count - 240)
        }
    }

    private func publishUploadState() {
        let rows = uploadRowStore.values.sorted { lhs, rhs in
            if uploadPhaseRank(lhs.phase) != uploadPhaseRank(rhs.phase) {
                return uploadPhaseRank(lhs.phase) < uploadPhaseRank(rhs.phase)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        uploadRows = rows
        activeUploads = rows.count(where: { $0.phase == .hashing || $0.phase == .uploading })
        uploadSummary = makeUploadSummary(rows: rows)
    }

    private func makeUploadSummary(rows: [UploadRowState]) -> UploadDashboardSummary {
        let snapshot = uploadBandwidthSnapshot
        let transferred = rows.reduce(Int64(0)) { $0 + $1.bytesTransferred }
        let total = rows.reduce(Int64(0)) { $0 + max($1.totalBytes, $1.bytesTransferred) }
        let currentBPS = snapshot?.currentBPS ?? rows.reduce(Double(0)) { $0 + $1.speedBPS }
        let remaining = max(0, total - transferred)
        return UploadDashboardSummary(
            activeCount: rows.count(where: { $0.phase == .hashing || $0.phase == .uploading }),
            queuedCount: rows.count(where: { $0.phase == .queued }),
            failedCount: rows.count(where: { $0.phase == .failed }),
            pausedCount: rows.count(where: { $0.phase == .paused }),
            completedCount: rows.count(where: { $0.phase == .completed }),
            bytesTransferred: transferred,
            totalBytes: total,
            currentBPS: currentBPS,
            peakBPS: snapshot?.peakBPS ?? 0,
            etaSeconds: currentBPS > 0 ? Double(remaining) / currentBPS : nil
        )
    }

    private func uploadPhaseRank(_ phase: UploadDisplayPhase) -> Int {
        switch phase {
        case .uploading, .hashing: 0
        case .queued: 1
        case .paused: 2
        case .failed: 3
        case .completed: 4
        case .cancelled, .skipped: 5
        }
    }

    // MARK: - Download Rows

    private func row(for task: DownloadTask, phase: DownloadDisplayPhase, detail: String) -> DownloadRowState {
        let totalBytes = task.expectedSize ?? 0
        return DownloadRowState(
            id: task.id,
            fileName: task.sourcePath.lastComponent,
            providerID: task.providerID,
            sourcePath: task.sourcePath.path,
            destinationPath: task.destinationURL.path,
            phase: phase,
            progress: 0,
            bytesReceived: 0,
            totalBytes: totalBytes,
            speedBPS: 0,
            etaSeconds: nil,
            rangeText: totalBytes > 0 ? "Waiting for byte-range slots" : "Waiting for metadata",
            detailText: detail,
            checksumVerified: false,
            updatedAt: Date()
        )
    }

    private func updateDownloadRow(id: UUID, phase: DownloadDisplayPhase, detail: String) {
        guard let existing = downloadRowStore[id] else { return }
        downloadRowStore[id] = DownloadRowState(
            id: existing.id,
            fileName: existing.fileName,
            providerID: existing.providerID,
            sourcePath: existing.sourcePath,
            destinationPath: existing.destinationPath,
            phase: phase,
            progress: existing.progress,
            bytesReceived: existing.bytesReceived,
            totalBytes: existing.totalBytes,
            speedBPS: existing.speedBPS,
            etaSeconds: existing.etaSeconds,
            rangeText: existing.rangeText,
            detailText: detail,
            checksumVerified: existing.checksumVerified,
            updatedAt: Date()
        )
    }

    private func updateDownloadRow(id: UUID, progress: DownloadProgress) {
        guard let existing = downloadRowStore[id] else { return }
        let total = progress.totalBytes ?? existing.totalBytes
        downloadRowStore[id] = DownloadRowState(
            id: existing.id,
            fileName: existing.fileName,
            providerID: existing.providerID,
            sourcePath: existing.sourcePath,
            destinationPath: existing.destinationPath,
            phase: .downloading,
            progress: progress.fractionCompleted ?? existing.progress,
            bytesReceived: progress.receivedBytes,
            totalBytes: total,
            speedBPS: progress.currentSpeedBPS,
            etaSeconds: progress.estimatedSecondsRemaining,
            rangeText: "Segment \(progress.segmentsCompleted)/\(progress.segmentsTotal) · \(progress.segmentsInFlight) in flight",
            detailText: "Live range download",
            checksumVerified: existing.checksumVerified,
            updatedAt: Date()
        )
    }

    private func updateDownloadRow(id: UUID, summary: DownloadSummary) {
        guard let existing = downloadRowStore[id] else { return }
        downloadRowStore[id] = DownloadRowState(
            id: existing.id,
            fileName: existing.fileName,
            providerID: existing.providerID,
            sourcePath: existing.sourcePath,
            destinationPath: summary.localURL.path,
            phase: .completed,
            progress: 1,
            bytesReceived: summary.totalBytes,
            totalBytes: summary.totalBytes,
            speedBPS: summary.averageBPS,
            etaSeconds: nil,
            rangeText: "\(summary.segmentsUsed) ranges",
            detailText: summary.checksumVerified ? "Checksum verified" : "Downloaded; checksum unavailable",
            checksumVerified: summary.checksumVerified,
            updatedAt: Date()
        )
    }

    private func publishDownloadState() {
        let rows = downloadRowStore.values.sorted { lhs, rhs in
            if downloadPhaseRank(lhs.phase) != downloadPhaseRank(rhs.phase) {
                return downloadPhaseRank(lhs.phase) < downloadPhaseRank(rhs.phase)
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        downloadRows = rows
        downloadSummary = makeDownloadSummary(rows: rows)
    }

    private func makeDownloadSummary(rows: [DownloadRowState]) -> DownloadDashboardSummary {
        let received = rows.reduce(Int64(0)) { $0 + $1.bytesReceived }
        let total = rows.reduce(Int64(0)) { $0 + max($1.totalBytes, $1.bytesReceived) }
        let currentBPS = rows
            .filter { $0.phase == .downloading }
            .reduce(Double(0)) { $0 + $1.speedBPS }
        let remaining = max(0, total - received)
        return DownloadDashboardSummary(
            activeCount: rows.count(where: { $0.phase == .downloading }),
            queuedCount: rows.count(where: { $0.phase == .queued || $0.phase == .restored }),
            failedCount: rows.count(where: { $0.phase == .failed }),
            pausedCount: rows.count(where: { $0.phase == .paused }),
            completedCount: rows.count(where: { $0.phase == .completed }),
            bytesReceived: received,
            totalBytes: total,
            currentBPS: currentBPS,
            etaSeconds: currentBPS > 0 ? Double(remaining) / currentBPS : nil
        )
    }

    private func downloadPhaseRank(_ phase: DownloadDisplayPhase) -> Int {
        switch phase {
        case .downloading: 0
        case .queued, .restored: 1
        case .paused: 2
        case .failed: 3
        case .completed: 4
        case .cancelled: 5
        }
    }

    // MARK: - Account Management

    public func addAccount(_ account: CloudAccount, config: ProviderAccountConfig? = nil) {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await accountStore.save(account)
                if let config {
                    try await providerConfigStore.save(config)
                }
                await registerProvider(for: account, config: config)
                try? await vfsMount.mount(account: account)
                await refreshMountRows()
                logger.info("Added persisted account: \(account.displayName)")
            } catch {
                logger.error("Failed to persist account \(account.id): \(error.localizedDescription)")
            }
        }
    }

    public func removeAccount(_ account: CloudAccount) {
        accounts.removeAll { $0.id == account.id }
        Task { [weak self] in
            do {
                try? await self?.vfsMount.unmount(account: account)
                await self?.refreshMountRows()
                try await self?.credentialVault.deleteAllCredentials(for: account)
                try await self?.providerConfigStore.delete(accountID: account.id)
                try await self?.accountStore.delete(id: account.id)
            } catch {
                await MainActor.run {
                    self?.logger.error("Failed to remove account \(account.id): \(error.localizedDescription)")
                }
            }
        }
    }

    public func addSyncPair(_ pair: SyncPair) async {
        activeSyncPairs.append(pair)
        await syncEngine.addPair(pair)
    }

    public func removeSyncPair(id: UUID) async {
        activeSyncPairs.removeAll { $0.id == id }
        await syncEngine.removePair(id: id)
    }

    // MARK: - Finder Mounts

    public func mountAccount(_ account: CloudAccount) async {
        do {
            try await vfsMount.mount(account: account)
            await refreshMountRows()
        } catch {
            logger.error("Failed to mount account \(account.id): \(error.localizedDescription)")
            await refreshMountRows()
        }
    }

    /// Returns a human-readable error string if mounting failed, otherwise nil.
    public func mountAccountReturningError(_ account: CloudAccount) async -> String? {
        do {
            try await vfsMount.mount(account: account)
            await refreshMountRows()
            return nil
        } catch {
            logger.error("Failed to mount account \(account.id): \(error.localizedDescription)")
            await refreshMountRows()
            return error.localizedDescription
        }
    }

    public func unmountAccount(_ account: CloudAccount) async {
        do {
            try await vfsMount.unmount(account: account)
            await refreshMountRows()
        } catch {
            logger.error("Failed to unmount account \(account.id): \(error.localizedDescription)")
            await refreshMountRows()
        }
    }

    public func refreshMountRows() async {
        let snapshots = await vfsMount.snapshots()
        mountRows = snapshots.map { snapshot in
            MountRow(
                id: snapshot.id,
                accountID: snapshot.accountID,
                accountName: snapshot.finderDisplayName,
                providerID: snapshot.providerID,
                mountPath: "Finder Locations",
                status: MountRow.Status(snapshot.status),
                statusMessage: snapshot.statusMessage,
                quotaUsed: 0,
                quotaTotal: nil,
                cacheUsed: 0
            )
        }
    }

    // MARK: - Provider Registration

    private func registerProvider(for account: CloudAccount, config: ProviderAccountConfig?) async {
        guard let provider = await makeProvider(for: account, config: config) else {
            logger.warning("Account \(account.id) is persisted but missing provider configuration")
            return
        }

        await providerRegistry.register(provider)
        await uploadEngine.registerProvider(provider, account: account)
        await downloadEngine.registerProvider(provider, account: account)
        await syncEngine.registerProvider(provider, account: account)
    }

    private func makeProvider(for account: CloudAccount, config: ProviderAccountConfig?) async -> (any CloudProvider)? {
        await CloudProviderFactory.makeProvider(for: account, config: config, credentialVault: credentialVault)
    }

    private func providerName(for providerID: String) -> String {
        ProviderDefinitionCatalog.shared.displayName(for: providerID)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
