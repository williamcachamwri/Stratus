import SwiftUI
import os.log

// MARK: - AppEnvironment
// Single source of truth for shared state and services injected into the SwiftUI environment.

@MainActor
public final class AppEnvironment: ObservableObject {
    public static let shared = AppEnvironment()

    // MARK: - Services
    let uploadEngine = UploadEngine.shared
    let syncEngine = SyncEngine.shared
    let syncScheduler = SyncScheduler.shared
    let providerRegistry = CloudProviderRegistry.shared

    // MARK: - Observable State
    @Published public var accounts: [CloudAccount] = []
    @Published public var activeSyncPairs: [SyncPair] = []
    @Published public var pendingConflicts: [SyncConflict] = []
    @Published public var uploadEvents: [UploadEngineEvent] = []
    @Published public var isOnline: Bool = true
    @Published public var activeUploads: Int = 0

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "AppEnvironment")
    private var uploadEventTask: Task<Void, Never>?
    private var syncEventTask: Task<Void, Never>?

    private init() {
        startListeningForEvents()
    }

    // MARK: - Event Listeners

    private func startListeningForEvents() {
        uploadEventTask = Task { @MainActor [weak self] in
            for await event in await self?.uploadEngine.events ?? AsyncStream { _ in } {
                self?.handleUploadEvent(event)
            }
        }

        syncEventTask = Task { @MainActor [weak self] in
            for await event in await self?.syncEngine.events ?? AsyncStream { _ in } {
                self?.handleSyncEvent(event)
            }
        }

        Task { @MainActor [weak self] in
            let reachability = NetworkReachability()
            for await isConnected in await reachability.changes {
                self?.isOnline = isConnected
            }
        }
    }

    private func handleUploadEvent(_ event: UploadEngineEvent) {
        uploadEvents.append(event)
        if uploadEvents.count > 200 { uploadEvents.removeFirst() }
        switch event {
        case .taskStarted:
            activeUploads += 1
        case .taskCompleted(let task):
            activeUploads = max(0, activeUploads - 1)
            StratusNotificationCenter.shared.notifyUploadComplete(
                fileName: task.fileURL.lastPathComponent,
                providerName: task.accountID
            )
            DockProgressManager.shared.updateUploadProgress(
                activeUploads > 0 ? 0.5 : 0, activeCount: activeUploads
            )
        case .taskFailed(let task, let error):
            activeUploads = max(0, activeUploads - 1)
            StratusNotificationCenter.shared.notifyUploadFailed(
                fileName: task.fileURL.lastPathComponent,
                error: error.localizedDescription
            )
        case .taskCancelled:
            activeUploads = max(0, activeUploads - 1)
        default: break
        }
    }

    private func handleSyncEvent(_ event: SyncEngineEvent) {
        if case .conflictDetected(let conflict) = event {
            pendingConflicts.append(conflict)
            StratusNotificationCenter.shared.notifySyncConflict(
                fileName: conflict.localURL.lastPathComponent,
                pairID: conflict.pairID
            )
            DockProgressManager.shared.updateConflictBadge(pendingConflicts.count)
        }
        if case .conflictResolved(let conflict, _) = event {
            pendingConflicts.removeAll { $0.id == conflict.id }
            DockProgressManager.shared.updateConflictBadge(pendingConflicts.count)
        }
        if case .syncCompleted(_, let up, let down, _) = event {
            StratusNotificationCenter.shared.notifySyncComplete(
                pairName: "Stratus", uploaded: up, downloaded: down
            )
        }
    }

    // MARK: - Account Management

    public func addAccount(_ account: CloudAccount) {
        accounts.append(account)
        logger.info("Added account: \(account.displayName)")
    }

    public func removeAccount(_ account: CloudAccount) {
        accounts.removeAll { $0.id == account.id }
    }

    public func addSyncPair(_ pair: SyncPair) async {
        activeSyncPairs.append(pair)
        await syncEngine.addPair(pair)
    }

    public func removeSyncPair(id: UUID) async {
        activeSyncPairs.removeAll { $0.id == id }
        await syncEngine.removePair(id: id)
    }
}
