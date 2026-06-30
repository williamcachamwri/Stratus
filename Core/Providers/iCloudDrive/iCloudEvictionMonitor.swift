import Foundation
import os.log

// MARK: - ICloudEvictionEvent

public enum ICloudEvictionEvent: Sendable {
    /// A file that was locally present has been evicted to iCloud-only storage.
    case fileEvicted(URL)
    /// A file that was evicted has been downloaded back to local storage.
    case fileDownloaded(URL)
}

// MARK: - ICloudEvictionMonitor

// Monitors iCloud Drive file eviction events via NSMetadataQuery.
// Notifies observers through an AsyncStream when files are evicted from
// local storage or successfully downloaded back.
//
// NSMetadataQuery is @MainActor-bound and non-Sendable. We schedule it on
// the main queue and communicate results back to the actor only through
// value types (no direct NSMetadataQuery capture across isolation boundaries).

public actor ICloudEvictionMonitor {
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "iCloudEvictionMonitor")

    /// Continuations for active event streams
    private var continuations: [UUID: AsyncStream<ICloudEvictionEvent>.Continuation] = [:]

    /// Snapshot of previous download statuses — keyed by file path
    private var previousStatuses: [String: String] = [:]

    /// Whether the main-queue NSMetadataQuery is currently running
    private var queryRunning = false

    public init() {}

    // MARK: - Public API

    /// Returns an AsyncStream that yields ICloudEvictionEvent values as iCloud
    /// Drive changes the local availability of files.
    public var events: AsyncStream<ICloudEvictionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
            Task { [weak self] in
                await self?.startQueryIfNeeded()
            }
        }
    }

    /// Stops monitoring and terminates all active streams.
    public func stop() {
        // Dispatch to main actor since EvictionQueryCoordinator is @MainActor-isolated
        Task { @MainActor in EvictionQueryCoordinator.shared.stopQuery() }
        queryRunning = false
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        previousStatuses.removeAll()
        logger.info("iCloudEvictionMonitor stopped")
    }

    // MARK: - Internal: called by the main-queue coordinator

    /// Receives batched metadata results from the NSMetadataQuery coordinator.
    /// Called by `EvictionQueryCoordinator` via an unstructured Task — parameters
    /// are all value types so no non-Sendable data crosses the boundary.
    func processBatch(_ batch: [(path: String, status: String)]) {
        for entry in batch {
            let previous = previousStatuses[entry.path]
            let url = URL(fileURLWithPath: entry.path)

            // Detect eviction: was current (local), now not current
            if previous == NSMetadataUbiquitousItemDownloadingStatusCurrent,
               entry.status != NSMetadataUbiquitousItemDownloadingStatusCurrent
            {
                logger.debug("File evicted: \(entry.path)")
                emit(.fileEvicted(url))
            }

            // Detect download: transitioned to current (from some prior state)
            if previous != NSMetadataUbiquitousItemDownloadingStatusCurrent,
               entry.status == NSMetadataUbiquitousItemDownloadingStatusCurrent,
               previous != nil
            {
                logger.debug("File downloaded: \(entry.path)")
                emit(.fileDownloaded(url))
            }

            previousStatuses[entry.path] = entry.status
        }
    }

    // MARK: - Private

    private func startQueryIfNeeded() {
        guard !queryRunning else { return }
        queryRunning = true
        let monitor = self
        Task { @MainActor in EvictionQueryCoordinator.shared.startQuery(monitor: monitor) }
        logger.info("iCloudEvictionMonitor started NSMetadataQuery via coordinator")
    }

    private func emit(_ event: ICloudEvictionEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            Task { @MainActor in EvictionQueryCoordinator.shared.stopQuery() }
            queryRunning = false
            logger.info("iCloudEvictionMonitor paused (no active subscribers)")
        }
    }
}

// MARK: - EvictionQueryCoordinator

// Lives on the main actor so it can safely own NSMetadataQuery.
// Converts NSMetadataQuery notifications into sendable value batches
// and forwards them to the ICloudEvictionMonitor actor.

@MainActor
private final class EvictionQueryCoordinator {
    static let shared = EvictionQueryCoordinator()

    private var query: NSMetadataQuery?
    private weak var monitor: ICloudEvictionMonitor?

    private init() {}

    func startQuery(monitor: ICloudEvictionMonitor) {
        self.monitor = monitor
        guard query == nil else { return }

        let metadataQuery = NSMetadataQuery()
        metadataQuery.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemPathKey)
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery.notificationBatchingInterval = 1.0

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate(_:)),
            name: .NSMetadataQueryDidUpdate,
            object: metadataQuery
        )

        metadataQuery.start()
        query = metadataQuery
    }

    func stopQuery() {
        guard let q = query else { return }
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: q)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: q)
        q.stop()
        query = nil
        monitor = nil
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        guard let q = notification.object as? NSMetadataQuery else { return }
        q.disableUpdates()
        defer { q.enableUpdates() }

        // Collect (path, status) pairs as pure value types — safe to send
        var batch: [(path: String, status: String)] = []
        for index in 0 ..< q.resultCount {
            guard let item = q.result(at: index) as? NSMetadataItem else { continue }
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let status = (item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String) ?? ""
            batch.append((path: path, status: status))
        }

        let capturedMonitor = monitor
        Task {
            await capturedMonitor?.processBatch(batch)
        }
    }
}
