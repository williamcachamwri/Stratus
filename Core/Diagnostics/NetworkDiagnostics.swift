import Foundation
import Network

// MARK: - Result Types

/// The result of a completed speed-test run.
public struct NetworkTestResult: Sendable {
    /// Effective download throughput in bytes/second.
    public let downloadBytesPerSecond: Double
    /// Total bytes transferred during the test.
    public let bytesReceived: Int
    /// Wall-clock duration of the test in seconds.
    public let durationSeconds: Double
    /// URL used for the speed test.
    public let sourceURL: URL

    /// Human-readable Mbps value (megabits, not megabytes).
    public var megabitsPerSecond: Double {
        (downloadBytesPerSecond * 8) / 1_000_000
    }
}

// MARK: - Errors

public enum NetworkDiagnosticsError: Error, Sendable {
    case invalidHost(String)
    case latencyProbeTimedOut(host: String, timeoutSeconds: Double)
    case speedTestFailed(url: URL, reason: String)
    case unexpectedResponse(statusCode: Int)
    case dataMissing
}

// MARK: - NetworkDiagnostics

/// Actor-isolated network diagnostics tool.
///
/// All methods are safe to call concurrently; each creates its own
/// `URLSession` task and does not share mutable state with siblings.
public actor NetworkDiagnostics {
    // MARK: Singleton

    public static let shared = NetworkDiagnostics()

    // MARK: Configuration

    private let defaultTimeoutSeconds: Double
    private let session: URLSession

    // MARK: Init

    public init(timeoutSeconds: Double = 10.0) {
        defaultTimeoutSeconds = timeoutSeconds

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds * 3
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    // MARK: - Latency Probe

    /// Measures round-trip latency to `host` by making an HTTP HEAD request
    /// to `https://<host>` and timing the full response arrival.
    ///
    /// - Parameter host: Hostname (e.g. `"apple.com"`). Must not be empty.
    /// - Returns: Round-trip time in seconds.
    /// - Throws: `NetworkDiagnosticsError.invalidHost` if `host` is empty.
    ///           `NetworkDiagnosticsError.latencyProbeTimedOut` on timeout.
    ///           `NetworkDiagnosticsError.unexpectedResponse` on non-2xx.
    public func runLatencyProbe(host: String) async throws -> TimeInterval {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NetworkDiagnosticsError.invalidHost(host)
        }

        // Build a simple HTTPS HEAD request
        var components = URLComponents()
        components.scheme = "https"
        components.host = trimmed
        components.path = "/"

        guard let url = components.url else {
            throw NetworkDiagnosticsError.invalidHost(host)
        }

        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.httpMethod = "HEAD"
            r.timeoutInterval = defaultTimeoutSeconds
            return r
        }()

        let start = Date()
        let (_, response) = try await withThrowingTimeout(seconds: defaultTimeoutSeconds) {
            try await self.session.data(for: request)
        } mapTimeout: {
            NetworkDiagnosticsError.latencyProbeTimedOut(
                host: trimmed,
                timeoutSeconds: self.defaultTimeoutSeconds
            )
        }
        let elapsed = Date().timeIntervalSince(start)

        if let httpResponse = response as? HTTPURLResponse {
            let code = httpResponse.statusCode
            guard (200 ... 399).contains(code) else {
                throw NetworkDiagnosticsError.unexpectedResponse(statusCode: code)
            }
        }

        return elapsed
    }

    // MARK: - Speed Test

    /// Downloads the resource at `downloadURL` and reports throughput.
    ///
    /// - Parameter downloadURL: A URL pointing to a known-size payload.
    /// - Returns: `NetworkTestResult` with throughput and byte counts.
    /// - Throws: `NetworkDiagnosticsError.speedTestFailed` on network failure,
    ///           `.unexpectedResponse` on non-2xx.
    public func runSpeedTest(downloadURL: URL) async throws -> NetworkTestResult {
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = defaultTimeoutSeconds * 3 // longer for large payloads

        let start = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NetworkDiagnosticsError.speedTestFailed(
                url: downloadURL,
                reason: error.localizedDescription
            )
        }
        let elapsed = max(Date().timeIntervalSince(start), 0.001) // avoid /0

        if let httpResponse = response as? HTTPURLResponse {
            let code = httpResponse.statusCode
            guard (200 ... 299).contains(code) else {
                throw NetworkDiagnosticsError.unexpectedResponse(statusCode: code)
            }
        }

        guard !data.isEmpty else {
            throw NetworkDiagnosticsError.dataMissing
        }

        let bytesPerSecond = Double(data.count) / elapsed

        return NetworkTestResult(
            downloadBytesPerSecond: bytesPerSecond,
            bytesReceived: data.count,
            durationSeconds: elapsed,
            sourceURL: downloadURL
        )
    }

    // MARK: - Connectivity Check

    /// Returns `true` if the device currently has a usable network path.
    ///
    /// Uses `NWPathMonitor` with a short observation window so this method
    /// completes quickly even on devices with slow path updates.
    public func checkConnectivity() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(
                label: "com.stratus.cloudmanager.connectivity",
                qos: .utility
            )
            // Use a class so both closures can safely share the flag.
            final class ResumeFlag: @unchecked Sendable {
                var value = false
            }
            let flag = ResumeFlag()

            monitor.pathUpdateHandler = { path in
                guard !flag.value else { return }
                flag.value = true
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }

            monitor.start(queue: queue)

            // Safety timeout: resolve as `false` after 3 seconds if no update arrives.
            queue.asyncAfter(deadline: .now() + 3) {
                guard !flag.value else { return }
                flag.value = true
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - Private Helpers

extension NetworkDiagnostics {
    /// Runs `operation` and maps a thrown `CancellationError` / timeout to a
    /// domain error produced by `mapTimeout`.
    ///
    /// Swift 6 does not have a built-in `withThrowingTimeout`; this minimal
    /// implementation uses a task group to race the operation against a sleep.
    private func withThrowingTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T,
        mapTimeout: @escaping @Sendable () -> NetworkDiagnosticsError
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw mapTimeout()
            }

            // Return the first result (success or failure) and cancel the other.
            let result = try await group.next()
            group.cancelAll()
            guard let value = result else {
                throw NetworkDiagnosticsError.dataMissing
            }
            return value
        }
    }
}
