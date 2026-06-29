import Foundation
import os.log

// MARK: - SyncEngine Event

public enum SyncEngineEvent: Sendable {
    case syncStarted(pairID: UUID)
    case syncCompleted(pairID: UUID, uploaded: Int, downloaded: Int, conflicts: Int)
    case syncFailed(pairID: UUID, error: Error)
    case fileUploaded(pairID: UUID, localURL: URL, remotePath: CloudPath)
    case fileDownloaded(pairID: UUID, remotePath: CloudPath, localURL: URL)
    case conflictDetected(SyncConflict)
    case conflictResolved(SyncConflict, ResolvedAction)
}

// MARK: - SyncEngine

public actor SyncEngine {
    public static let shared = SyncEngine()

    private var pairs: [UUID: SyncPair] = [:]
    private var providers: [String: any CloudProvider] = [:]
    private var accounts: [String: CloudAccount] = [:]
    private let conflictResolver = ConflictResolver()
    private let changeJournal = ChangeJournal.shared
    private let uploadEngine = UploadEngine.shared

    private var syncTasks: [UUID: Task<Void, Never>] = [:]
    private var eventContinuation: AsyncStream<SyncEngineEvent>.Continuation?
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SyncEngine")

    public private(set) lazy var events: AsyncStream<SyncEngineEvent> = AsyncStream { [weak self] continuation in
        Task { await self?.setEventContinuation(continuation) }
    }

    private init() {}

    // MARK: - Setup

    public func registerProvider(_ provider: any CloudProvider, account: CloudAccount) {
        providers[account.id] = provider
        accounts[account.id] = account
    }

    public func addPair(_ pair: SyncPair) async {
        pairs[pair.id] = pair
        if pair.enabled {
            await startWatching(pair: pair)
        }
    }

    public func removePair(id: UUID) async {
        pairs.removeValue(forKey: id)
        await changeJournal.stopWatching(pairID: id)
        syncTasks[id]?.cancel()
        syncTasks.removeValue(forKey: id)
    }

    // MARK: - Trigger Sync

    public func syncNow(pairID: UUID) async {
        guard let pair = pairs[pairID], pair.enabled else { return }
        guard let provider = providers[pair.accountID], let account = accounts[pair.accountID] else { return }
        syncTasks[pairID]?.cancel()
        syncTasks[pairID] = Task { await runSync(pair: pair, provider: provider, account: account) }
    }

    public func syncAll() async {
        for pair in pairs.values where pair.enabled {
            await syncNow(pairID: pair.id)
        }
    }

    // MARK: - Watch + React to Changes

    private func startWatching(pair: SyncPair) async {
        await changeJournal.startWatching(pair: pair)
        let eventStream = await changeJournal.events(for: pair.id)
        Task { [weak self] in
            for await event in eventStream {
                await self?.handleLocalChange(event, pair: pair)
            }
        }
    }

    private func handleLocalChange(_ event: ChangeEvent, pair: SyncPair) async {
        guard let provider = providers[pair.accountID], let account = accounts[pair.accountID] else { return }
        let fileName = event.localURL.lastPathComponent

        // Apply exclusion rules
        let ext = event.localURL.pathExtension
        for rule in pair.rules where rule.type == .exclude {
            if rule.matches(path: event.localURL.path, name: fileName, fileExtension: ext) {
                logger.debug("Excluded by rule: \(fileName)")
                return
            }
        }

        guard pair.mode != .oneWayDownload else { return }

        switch event.changeType {
        case .created, .modified:
            let relative = event.localURL.path.replacingOccurrences(of: pair.localPath.path + "/", with: "")
            let remotePath = pair.remotePath.appendingComponent(relative)
            do {
                _ = try await uploadEngine.upload(
                    fileURL: event.localURL,
                    destination: remotePath,
                    accountID: pair.accountID,
                    priority: .normal
                )
                emit(.fileUploaded(pairID: pair.id, localURL: event.localURL, remotePath: remotePath))
            } catch {
                logger.error("Upload failed for \(fileName): \(error)")
            }
        case .deleted:
            guard pair.mode == .mirror else { return }
            let relative = event.localURL.path.replacingOccurrences(of: pair.localPath.path + "/", with: "")
            let remotePath = pair.remotePath.appendingComponent(relative)
            try? await provider.delete(path: remotePath, account: account)
        case .renamed, .moved:
            break  // Handled via delete+create events from FSEvents
        }
    }

    // MARK: - Full Sync Pass

    private func runSync(pair: SyncPair, provider: any CloudProvider, account: CloudAccount) async {
        emit(.syncStarted(pairID: pair.id))
        var uploaded = 0, downloaded = 0, conflicts = 0

        do {
            let remoteItems = try await fetchAllRemoteItems(path: pair.remotePath, provider: provider, account: account)
            let localItems = try fetchAllLocalItems(at: pair.localPath)

            let remoteByName = Dictionary(remoteItems.map { ($0.name, $0) }, uniquingKeysWith: { _, new in new })
            let localByName = Dictionary(localItems.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { _, new in new })

            // Upload local-only files
            if pair.mode != .oneWayDownload {
                for (name, localURL) in localByName where remoteByName[name] == nil {
                    let remotePath = pair.remotePath.appendingComponent(name)
                    if shouldExclude(url: localURL, rules: pair.rules) { continue }
                    _ = try await uploadEngine.upload(fileURL: localURL, destination: remotePath, accountID: pair.accountID, priority: .low)
                    emit(.fileUploaded(pairID: pair.id, localURL: localURL, remotePath: remotePath))
                    uploaded += 1
                }
            }

            // Download remote-only files
            if pair.mode != .oneWayUpload && pair.mode != .mirror {
                for (name, remoteItem) in remoteByName where localByName[name] == nil {
                    let localURL = pair.localPath.appendingPathComponent(name)
                    let downloadURL = try await provider.downloadURL(path: remoteItem.path, account: account, expiresIn: 3600)
                    let (data, _) = try await URLSession.shared.data(from: downloadURL)
                    try data.write(to: localURL)
                    emit(.fileDownloaded(pairID: pair.id, remotePath: remoteItem.path, localURL: localURL))
                    downloaded += 1
                }
            }

            // Handle files that exist on both sides
            if pair.mode == .bidirectional || pair.mode == .mirror {
                for (name, remoteItem) in remoteByName {
                    guard let localURL = localByName[name] else { continue }
                    let localMod = (try? localURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let remoteMod = remoteItem.modifiedAt ?? Date.distantPast

                    let localChanged = abs(localMod.timeIntervalSinceNow) < 86400
                    let remoteChanged = abs(remoteMod.timeIntervalSinceNow) < 86400

                    if localChanged && remoteChanged {
                        let localSize = (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                        let conflict = SyncConflict(pairID: pair.id, localURL: localURL,
                                                     remotePath: remoteItem.path,
                                                     localModDate: localMod, remoteModDate: remoteMod,
                                                     localSize: localSize, remoteSize: remoteItem.size ?? 0)
                        emit(.conflictDetected(conflict))
                        let action = try await conflictResolver.resolve(conflict: conflict, resolution: pair.conflictResolution, provider: provider, account: account)
                        emit(.conflictResolved(conflict, action))
                        try await executeAction(action, provider: provider, account: account, pair: pair)
                        conflicts += 1
                    }
                }
            }

            emit(.syncCompleted(pairID: pair.id, uploaded: uploaded, downloaded: downloaded, conflicts: conflicts))
            logger.info("Sync complete for \(pair.id): +\(uploaded) up, +\(downloaded) down, \(conflicts) conflicts")
        } catch {
            emit(.syncFailed(pairID: pair.id, error: error))
            logger.error("Sync failed for \(pair.id): \(error)")
        }
    }

    private func executeAction(_ action: ResolvedAction, provider: any CloudProvider, account: CloudAccount, pair: SyncPair) async throws {
        switch action {
        case .upload(let localURL, let remotePath):
            _ = try await uploadEngine.upload(fileURL: localURL, destination: remotePath, accountID: pair.accountID, priority: .normal)
        case .download(let remotePath, let localURL):
            let url = try await provider.downloadURL(path: remotePath, account: account, expiresIn: 3600)
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: localURL)
        case .keepBoth(let uploadURL, let remotePath, let downloadTo, let conflictCopy):
            _ = try await uploadEngine.upload(fileURL: uploadURL, destination: remotePath, accountID: pair.accountID, priority: .normal)
            let url = try await provider.downloadURL(path: remotePath, account: account, expiresIn: 3600)
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: conflictCopy)
        case .needsUserDecision, .skip:
            break
        }
    }

    private func fetchAllRemoteItems(path: CloudPath, provider: any CloudProvider, account: CloudAccount) async throws -> [CloudFileItem] {
        var all: [CloudFileItem] = []
        var pageToken: String? = nil
        repeat {
            let result = try await provider.listDirectory(path: path, account: account, pageToken: pageToken)
            all.append(contentsOf: result.items)
            pageToken = result.nextPageToken
        } while pageToken != nil
        return all
    }

    private func fetchAllLocalItems(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
    }

    private func shouldExclude(url: URL, rules: [SyncRule]) -> Bool {
        let name = url.lastPathComponent
        let ext = url.pathExtension
        return rules.filter { $0.type == .exclude }.contains { $0.matches(path: url.path, name: name, fileExtension: ext) }
    }

    private func emit(_ event: SyncEngineEvent) {
        eventContinuation?.yield(event)
    }

    private func setEventContinuation(_ continuation: AsyncStream<SyncEngineEvent>.Continuation) {
        eventContinuation = continuation
    }
}
