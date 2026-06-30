import Foundation
import Network
import os.log

// MARK: - Connection Types

public enum ConnectionType: Sendable, Equatable {
    case wifi
    case cellular
    case ethernet
    case none
}

public struct ConnectionStatus: Sendable, Equatable {
    public let isConnected: Bool
    public let type: ConnectionType

    public init(isConnected: Bool, type: ConnectionType) {
        self.isConnected = isConnected
        self.type = type
    }
}

// MARK: - NetworkReachability

/// NWPathMonitor-backed actor that tracks current connectivity and
/// vends an AsyncStream of `ConnectionStatus` updates.
///
/// Replaces the simpler `NetworkReachability` in HTTPClient.swift with
/// richer `ConnectionType` semantics and the `updates` stream.
public actor NetworkReachabilityMonitor {
    public static let shared = NetworkReachabilityMonitor()

    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(
        label: "com.stratus.reachability",
        qos: .utility
    )
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "Reachability")

    /// Most recently observed path
    private var latestPath: NWPath?

    /// Active stream continuations keyed by UUID for O(1) removal
    private var continuations: [UUID: AsyncStream<ConnectionStatus>.Continuation] = [:]

    // MARK: - Init

    private init() {
        monitor = NWPathMonitor()
    }

    // MARK: - Lifecycle

    /// Starts the underlying NWPathMonitor.  Call once at app launch.
    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.handlePathUpdate(path) }
        }
        monitor.start(queue: monitorQueue)
        logger.info("NetworkReachabilityMonitor started")
    }

    /// Cancels the underlying NWPathMonitor and finishes all active streams.
    public func stop() {
        monitor.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        logger.info("NetworkReachabilityMonitor stopped")
    }

    // MARK: - Current state

    /// `true` when the latest observed network path can carry traffic.
    public var isConnected: Bool {
        latestPath?.status == .satisfied
    }

    /// The interface type of the current connection.
    public var connectionType: ConnectionType {
        guard let path = latestPath, path.status == .satisfied else {
            return .none
        }
        return Self.classify(path)
    }

    // MARK: - Async stream

    /// An `AsyncStream` that emits a `ConnectionStatus` whenever the
    /// network path changes.  The stream never completes unless `stop()`
    /// is called or the caller cancels its `Task`.
    public var updates: AsyncStream<ConnectionStatus> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id: id) }
            }
            // Immediately emit the current status so callers don't have to wait.
            if let path = latestPath {
                let status = ConnectionStatus(
                    isConnected: path.status == .satisfied,
                    type: Self.classify(path)
                )
                continuation.yield(status)
            }
        }
    }

    // MARK: - Private

    private func handlePathUpdate(_ path: NWPath) {
        let previous = latestPath
        latestPath = path

        let newStatus = ConnectionStatus(
            isConnected: path.status == .satisfied,
            type: Self.classify(path)
        )

        let previousStatus: ConnectionStatus? = previous.map {
            ConnectionStatus(
                isConnected: $0.status == .satisfied,
                type: Self.classify($0)
            )
        }

        // Only broadcast if something meaningful changed.
        guard newStatus != previousStatus else { return }

        logger
            .info("Reachability changed: connected=\(newStatus.isConnected) type=\(String(describing: newStatus.type))")

        for continuation in continuations.values {
            continuation.yield(newStatus)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private static func classify(_ path: NWPath) -> ConnectionType {
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.cellular) { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        return .none
    }
}
