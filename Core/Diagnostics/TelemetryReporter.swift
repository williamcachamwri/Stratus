// TelemetryReporter.swift
// StratusCore — Anonymous performance / crash-metrics collector
//
// No network transmission — all data is stored locally.
// Records: upload speeds, chunk error rates, session durations.
//
// Swift 6: actor-isolated, no force-unwraps, typed errors.

import Foundation

// MARK: - Telemetry Event Types

/// The kind of event captured by the telemetry system.
public enum TelemetryEventKind: String, Sendable, Codable, CaseIterable {
    case uploadSpeed      = "upload_speed"       // Bytes/sec for a completed upload
    case downloadSpeed    = "download_speed"     // Bytes/sec for a completed download
    case chunkError       = "chunk_error"        // A chunk-level transfer failure
    case sessionDuration  = "session_duration"   // Seconds a user session lasted
    case syncCycle        = "sync_cycle"         // Duration of one full sync pass
    case providerError    = "provider_error"     // An unrecoverable provider-level error
    case encryptionTiming = "encryption_timing"  // Milliseconds to encrypt/decrypt data
}

// MARK: - TelemetryEvent

/// A single captured telemetry data-point.
public struct TelemetryEvent: Sendable, Codable {
    /// Stable identifier for this event instance.
    public let id: UUID
    /// The category of measurement.
    public let kind: TelemetryEventKind
    /// Primary numeric measurement (unit depends on `kind`).
    public let value: Double
    /// Optional free-form metadata (provider name, error code, etc.).
    public let metadata: [String: String]
    /// When the event was recorded (seconds since Unix epoch).
    public let timestamp: Double

    public init(
        id: UUID = UUID(),
        kind: TelemetryEventKind,
        value: Double,
        metadata: [String: String] = [:],
        timestamp: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.kind = kind
        self.value = value
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

// MARK: - Aggregated Summary

/// Computed statistics for a given event kind over a recording window.
public struct TelemetrySummary: Sendable {
    public let kind: TelemetryEventKind
    public let count: Int
    public let mean: Double
    public let min: Double
    public let max: Double
    public let p95: Double   // 95th percentile

    public init(kind: TelemetryEventKind, samples: [Double]) {
        self.kind = kind
        self.count = samples.count

        guard !samples.isEmpty else {
            mean = 0; min = 0; max = 0; p95 = 0
            return
        }

        let sorted = samples.sorted()
        mean = sorted.reduce(0, +) / Double(sorted.count)
        min  = sorted.first ?? 0
        max  = sorted.last ?? 0

        let p95Index = Int(ceil(Double(sorted.count) * 0.95)) - 1
        p95 = sorted[Swift.max(0, Swift.min(p95Index, sorted.count - 1))]
    }
}

// MARK: - Errors

public enum TelemetryError: Error, Sendable {
    case exportEncodingFailed(underlying: Error)
    case storageFull(limit: Int)
}

// MARK: - TelemetryReporter

/// Actor-isolated, local-only telemetry recorder.
///
/// Events are held in memory up to `storageLimit`. Callers can persist them
/// via `exportMetrics()` at any time (e.g., on app background / termination).
public actor TelemetryReporter {

    // MARK: Singleton

    public static let shared = TelemetryReporter()

    // MARK: Configuration

    /// Maximum number of events held in memory before oldest are evicted.
    private let storageLimit: Int

    // MARK: State

    private var events: [TelemetryEvent] = []

    /// Wall-clock start of the current logical session.
    private var sessionStart: Date?

    // MARK: Init

    public init(storageLimit: Int = 10_000) {
        self.storageLimit = storageLimit
    }

    // MARK: - Session Tracking

    /// Marks the start of a new user session.
    public func beginSession() {
        sessionStart = Date()
    }

    /// Ends the current session and records a `sessionDuration` event.
    public func endSession() {
        guard let start = sessionStart else { return }
        let duration = Date().timeIntervalSince(start)
        sessionStart = nil
        let event = TelemetryEvent(kind: .sessionDuration, value: duration)
        append(event)
    }

    // MARK: - Recording

    /// Records a pre-built `TelemetryEvent`.
    public func record(event: TelemetryEvent) throws {
        guard events.count < storageLimit else {
            throw TelemetryError.storageFull(limit: storageLimit)
        }
        append(event)
    }

    /// Convenience: record an upload speed sample.
    /// - Parameter bytesPerSecond: Transfer throughput in bytes/sec.
    /// - Parameter providerID: Optional provider identifier.
    public func recordUploadSpeed(
        bytesPerSecond: Double,
        providerID: String? = nil
    ) throws {
        var meta: [String: String] = [:]
        if let pid = providerID { meta["provider"] = pid }
        try record(event: TelemetryEvent(kind: .uploadSpeed,
                                          value: bytesPerSecond,
                                          metadata: meta))
    }

    /// Convenience: record a download speed sample.
    public func recordDownloadSpeed(
        bytesPerSecond: Double,
        providerID: String? = nil
    ) throws {
        var meta: [String: String] = [:]
        if let pid = providerID { meta["provider"] = pid }
        try record(event: TelemetryEvent(kind: .downloadSpeed,
                                          value: bytesPerSecond,
                                          metadata: meta))
    }

    /// Convenience: record a chunk-level transfer error.
    /// - Parameter chunkIndex: Zero-based index of the failed chunk.
    /// - Parameter errorCode: Domain-specific error code string.
    public func recordChunkError(
        chunkIndex: Int,
        errorCode: String,
        providerID: String? = nil
    ) throws {
        var meta: [String: String] = ["chunk_index": "\(chunkIndex)",
                                       "error_code": errorCode]
        if let pid = providerID { meta["provider"] = pid }
        try record(event: TelemetryEvent(kind: .chunkError,
                                          value: 1,
                                          metadata: meta))
    }

    /// Convenience: record a sync-cycle duration.
    public func recordSyncCycle(durationSeconds: Double) throws {
        try record(event: TelemetryEvent(kind: .syncCycle,
                                          value: durationSeconds))
    }

    /// Convenience: record an encryption or decryption operation duration.
    public func recordEncryptionTiming(milliseconds: Double) throws {
        try record(event: TelemetryEvent(kind: .encryptionTiming,
                                          value: milliseconds))
    }

    // MARK: - Export

    /// Returns a snapshot of all recorded events in chronological order.
    public func exportMetrics() -> [TelemetryEvent] {
        events
    }

    /// Returns aggregated `TelemetrySummary` for each event kind present.
    public func exportSummaries() -> [TelemetrySummary] {
        var buckets: [TelemetryEventKind: [Double]] = [:]
        for event in events {
            buckets[event.kind, default: []].append(event.value)
        }
        return buckets.map { kind, samples in
            TelemetrySummary(kind: kind, samples: samples)
        }.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    /// Encodes all recorded events to JSON `Data`.
    public func exportJSON() throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(events)
        } catch {
            throw TelemetryError.exportEncodingFailed(underlying: error)
        }
    }

    /// Discards all stored events and resets the session.
    public func reset() {
        events.removeAll()
        sessionStart = nil
    }

    // MARK: - Private Helpers

    /// Appends an event, evicting the oldest entry if the store is full.
    private func append(_ event: TelemetryEvent) {
        if events.count >= storageLimit {
            events.removeFirst()
        }
        events.append(event)
    }
}
