// DiagnosticReport.swift
// StratusCore — Generates a diagnostic bundle for support
//
// Collects: app logs (from os.log via OSLogStore), upload/download metrics
// from TelemetryReporter, and network stats from NetworkDiagnostics.
//
// exportReport() archives everything into a timestamped directory in the
// system temp folder and returns the URL. (ZIP creation requires a
// third-party library; callers that need a .zip can compress the returned
// directory themselves.)
//
// Swift 6: actor-isolated, no force-unwraps, typed errors.

import Foundation
import OSLog

// MARK: - Errors

public enum DiagnosticReportError: Error, Sendable {
    case cannotCreateOutputDirectory(path: String, reason: String)
    case logExportFailed(reason: String)
    case metricsEncodingFailed(underlying: Error)
    case networkProbeFailed(host: String, underlying: Error)
    case fileWriteFailed(filename: String, reason: String)
}

// MARK: - DiagnosticReport

/// Actor-isolated diagnostic bundle generator.
///
/// Call `exportReport()` to collect all available diagnostics and write them
/// to a timestamped directory under `FileManager.default.temporaryDirectory`.
/// The returned URL is the root of that directory — suitable for sharing or
/// compressing via `Process` / `NSFileCoordinatedWrite`.
public actor DiagnosticReport {

    // MARK: Singleton

    public static let shared = DiagnosticReport()

    // MARK: Dependencies

    private let telemetry: TelemetryReporter
    private let networkDiagnostics: NetworkDiagnostics
    private let fileManager: FileManager

    // MARK: Configuration

    /// Hosts probed for latency during report generation.
    private let latencyProbeHosts: [String] = [
        "apple.com",
        "cloudflare.com",
        "1.1.1.1",
    ]

    /// Maximum number of os.log entries to include in the bundle.
    private let maxLogEntries: Int = 500

    // MARK: Init

    public init(
        telemetry: TelemetryReporter = .shared,
        networkDiagnostics: NetworkDiagnostics = .shared
    ) {
        self.telemetry = telemetry
        self.networkDiagnostics = networkDiagnostics
        self.fileManager = .default
    }

    // MARK: - Export

    /// Collects all diagnostics and writes them to a directory in the temp folder.
    ///
    /// The directory is named `stratus-diagnostics-<ISO8601 timestamp>`.
    /// Contents:
    ///   - `metrics.json`        — TelemetryReporter event log
    ///   - `summaries.json`      — Aggregated metric summaries
    ///   - `network_latency.json`— Latency probe results
    ///   - `os_log.txt`          — Recent structured log entries from OSLogStore
    ///   - `manifest.json`       — Metadata about the bundle itself
    ///
    /// - Returns: URL of the output directory.
    /// - Throws: `DiagnosticReportError` describing the first failure encountered.
    public func exportReport() async throws -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dirName = "stratus-diagnostics-\(timestamp)"
        let outputDir = fileManager.temporaryDirectory.appending(
            path: dirName,
            directoryHint: .isDirectory
        )

        // Create output directory
        do {
            try fileManager.createDirectory(
                at: outputDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw DiagnosticReportError.cannotCreateOutputDirectory(
                path: outputDir.path(percentEncoded: false),
                reason: error.localizedDescription
            )
        }

        // Collect all sections concurrently, gathering partial failures
        async let metricsResult   = collectMetrics(outputDir: outputDir)
        async let networkResult   = collectNetworkLatency(outputDir: outputDir)
        async let logResult       = collectOSLog(outputDir: outputDir)

        // Await and surface the first error (rethrows)
        try await metricsResult
        try await networkResult
        try await logResult

        // Write manifest last — it can reference file sizes
        try await writeManifest(outputDir: outputDir, timestamp: timestamp)

        return outputDir
    }

    // MARK: - Section Collectors

    /// Encodes TelemetryReporter events and summaries to JSON files.
    private func collectMetrics(outputDir: URL) async throws {
        // Raw events
        let eventsJSON: Data
        do {
            eventsJSON = try await telemetry.exportJSON()
        } catch {
            throw DiagnosticReportError.metricsEncodingFailed(underlying: error)
        }
        try write(data: eventsJSON, named: "metrics.json", in: outputDir)

        // Aggregated summaries
        let summaries = await telemetry.exportSummaries()
        let summaryPayload = summaries.map { summary -> [String: Any] in
            [
                "kind":  summary.kind.rawValue,
                "count": summary.count,
                "mean":  summary.mean,
                "min":   summary.min,
                "max":   summary.max,
                "p95":   summary.p95,
            ]
        }
        let summaryData: Data
        do {
            summaryData = try JSONSerialization.data(
                withJSONObject: summaryPayload,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw DiagnosticReportError.metricsEncodingFailed(underlying: error)
        }
        try write(data: summaryData, named: "summaries.json", in: outputDir)
    }

    /// Probes latency to well-known hosts and writes results to JSON.
    private func collectNetworkLatency(outputDir: URL) async throws {
        var results: [[String: Any]] = []

        for host in latencyProbeHosts {
            var entry: [String: Any] = ["host": host]
            do {
                let latency = try await networkDiagnostics.runLatencyProbe(host: host)
                entry["latency_ms"] = latency * 1000
                entry["success"]    = true
            } catch {
                entry["success"] = false
                entry["error"]   = error.localizedDescription
            }
            results.append(entry)
        }

        let isConnected = await networkDiagnostics.checkConnectivity()
        let payload: [String: Any] = [
            "connected": isConnected,
            "probes":    results,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw DiagnosticReportError.metricsEncodingFailed(underlying: error)
        }
        try write(data: data, named: "network_latency.json", in: outputDir)
    }

    /// Exports recent os.log entries from the Stratus subsystem.
    private func collectOSLog(outputDir: URL) async throws {
        let logText: String

        do {
            logText = try fetchOSLogEntries()
        } catch {
            // Non-fatal: write a placeholder so the bundle is still complete.
            let placeholder = "os.log export unavailable: \(error.localizedDescription)\n"
            guard let placeholderData = placeholder.data(using: .utf8) else { return }
            try write(data: placeholderData, named: "os_log.txt", in: outputDir)
            return
        }

        guard let logData = logText.data(using: .utf8) else {
            throw DiagnosticReportError.logExportFailed(reason: "UTF-8 encoding failed")
        }
        try write(data: logData, named: "os_log.txt", in: outputDir)
    }

    /// Writes a manifest describing the bundle.
    private func writeManifest(outputDir: URL, timestamp: String) async throws {
        var fileEntries: [[String: Any]] = []

        let contents = (try? fileManager.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []

        for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var entry: [String: Any] = ["name": fileURL.lastPathComponent]
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                entry["size_bytes"] = size
            }
            fileEntries.append(entry)
        }

        let manifest: [String: Any] = [
            "bundle_version":    1,
            "generated_at":      timestamp,
            "app_subsystem":     "com.stratus.cloudmanager",
            "platform":          "macOS",
            "files":             fileEntries,
        ]

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw DiagnosticReportError.metricsEncodingFailed(underlying: error)
        }
        try write(data: data, named: "manifest.json", in: outputDir)
    }

    // MARK: - os.log Fetch

    /// Reads up to `maxLogEntries` entries from the OSLogStore for the
    /// Stratus subsystem.
    private func fetchOSLogEntries() throws -> String {
        let store: OSLogStore
        do {
            store = try OSLogStore(scope: .currentProcessIdentifier)
        } catch {
            throw DiagnosticReportError.logExportFailed(
                reason: "OSLogStore init failed: \(error.localizedDescription)"
            )
        }

        // Look back one hour
        let oneHourAgo = store.position(date: Date(timeIntervalSinceNow: -3600))
        let predicate  = NSPredicate(
            format: "subsystem == %@",
            "com.stratus.cloudmanager"
        )

        let entries: [OSLogEntry]
        do {
            entries = try Array(
                store.getEntries(at: oneHourAgo, matching: predicate)
                    .prefix(maxLogEntries)
            )
        } catch {
            throw DiagnosticReportError.logExportFailed(
                reason: "getEntries failed: \(error.localizedDescription)"
            )
        }

        let lines = entries.compactMap { entry -> String? in
            guard let msg = entry as? OSLogEntryLog else { return nil }
            let levelTag: String
            switch msg.level {
            case .debug:   levelTag = "DEBUG"
            case .info:    levelTag = "INFO"
            case .notice:  levelTag = "NOTICE"
            case .error:   levelTag = "ERROR"
            case .fault:   levelTag = "FAULT"
            default:       levelTag = "OTHER"
            }
            let ts = ISO8601DateFormatter().string(from: msg.date)
            return "[\(ts)] [\(levelTag)] [\(msg.category)] \(msg.composedMessage)"
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - File I/O Helper

    /// Atomically writes `data` to `<outputDir>/<name>`.
    private func write(data: Data, named name: String, in directory: URL) throws {
        let fileURL = directory.appending(path: name, directoryHint: .notDirectory)
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw DiagnosticReportError.fileWriteFailed(
                filename: name,
                reason: error.localizedDescription
            )
        }
    }
}
