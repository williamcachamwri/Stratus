import Foundation
import os.log

// MARK: - SyncSchedule

public struct SyncSchedule: Codable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        case manual
        case onFileChange
        case periodic
        case onAppLaunch
        case onNetworkReconnect
    }

    public var triggers: Set<Trigger>
    public var periodicIntervalMinutes: Int  // Used only if .periodic in triggers
    public var skipOnBattery: Bool
    public var skipOnMeteredConnection: Bool

    public static let `default` = SyncSchedule(
        triggers: [.onFileChange, .onAppLaunch, .onNetworkReconnect],
        periodicIntervalMinutes: 30,
        skipOnBattery: false,
        skipOnMeteredConnection: true
    )
}

// MARK: - SyncScheduler

public actor SyncScheduler {
    public static let shared = SyncScheduler()

    private let engine = SyncEngine.shared
    private var schedules: [UUID: SyncSchedule] = [:]
    private var periodicTimers: [UUID: Task<Void, Never>] = [:]
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SyncScheduler")

    private init() {
        Task { await listenForNetworkReconnect() }
    }

    // MARK: - Schedule Management

    public func setSchedule(_ schedule: SyncSchedule, for pairID: UUID) {
        schedules[pairID] = schedule
        if schedule.triggers.contains(.periodic) {
            startPeriodicTimer(pairID: pairID, intervalMinutes: schedule.periodicIntervalMinutes)
        } else {
            periodicTimers[pairID]?.cancel()
            periodicTimers.removeValue(forKey: pairID)
        }
    }

    public func triggerManual(pairID: UUID) async {
        await engine.syncNow(pairID: pairID)
    }

    // MARK: - App Launch Sync

    public func onAppLaunch() async {
        for (pairID, schedule) in schedules where schedule.triggers.contains(.onAppLaunch) {
            logger.info("App launch sync for pair \(pairID)")
            await engine.syncNow(pairID: pairID)
        }
    }

    // MARK: - Periodic Timer

    private func startPeriodicTimer(pairID: UUID, intervalMinutes: Int) {
        periodicTimers[pairID]?.cancel()
        periodicTimers[pairID] = Task { [weak self] in
            let interval = UInt64(intervalMinutes) * 60 * 1_000_000_000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { break }
                await self?.engine.syncNow(pairID: pairID)
            }
        }
    }

    // MARK: - Network Reconnect

    private func listenForNetworkReconnect() async {
        let reachability = NetworkReachability()
        for await isConnected in await reachability.changes {
            if isConnected {
                logger.info("Network reconnected — triggering sync for eligible pairs")
                for (pairID, schedule) in schedules where schedule.triggers.contains(.onNetworkReconnect) {
                    await engine.syncNow(pairID: pairID)
                }
            }
        }
    }
}
