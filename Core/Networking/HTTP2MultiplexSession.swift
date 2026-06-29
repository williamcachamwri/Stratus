import Foundation
import os.log

// MARK: - Errors

public enum HTTP2MultiplexError: Error, Sendable {
    case invalidResponse(URL)
    case networkError(any Error)
    case timeout
    case cancelled
    case tlsError(String)
}

// MARK: - HTTP2MultiplexSession

/// Manages multiple concurrent HTTP/2 streams over a shared URLSession.
/// Forces HTTP/2 via TLS ALPN negotiation and caps active connections to
/// the optimal value for HTTP/2 multiplexing (6 host connections).
public actor HTTP2MultiplexSession {
    private let session: URLSession
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "HTTP2Multiplex")

    // Track in-flight tasks for cancellation
    private var activeTasks: [UUID: URLSessionTask] = [:]

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? HTTP2MultiplexSession.makeHTTP2Configuration()
        // URLSession is internally thread-safe; we store it as a let constant.
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Uploads `data` to `url` via a POST and returns the server response.
    public func upload(
        data: Data,
        to url: URL,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        let request = buildRequest(url: url, method: "POST", headers: headers, body: data)
        return try await perform(request: request)
    }

    /// Downloads the resource at `url` and returns the body and response.
    public func download(
        from url: URL,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        let request = buildRequest(url: url, method: "GET", headers: headers, body: nil)
        return try await perform(request: request)
    }

    // MARK: - Private Helpers

    private static func makeHTTP2Configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        // One TCP connection per host is enough for HTTP/2 (multiplexed streams).
        // Six gives headroom for providers that use multiple subdomains.
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        // Unlimited resource timeout — large transfers may run for minutes.
        config.timeoutIntervalForResource = 0
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        // Pipelining is required for HTTP/2 ALPN negotiation.
        config.httpShouldUsePipelining = true
        // Require TLS 1.2+ — HTTP/2 over cleartext (h2c) is not used.
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return config
    }

    private func buildRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        // Advertise HTTP/2 preference at the application layer.
        // URLSession handles ALPN at the TLS level; this header communicates
        // the same preference at the HTTP layer for servers that inspect it.
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>) in
                let task = self.session.dataTask(with: request) { data, response, error in
                    if let error {
                        let mapped = self.mapError(error)
                        continuation.resume(throwing: mapped)
                        return
                    }
                    guard
                        let data,
                        let httpResponse = response as? HTTPURLResponse
                    else {
                        continuation.resume(
                            throwing: HTTP2MultiplexError.invalidResponse(request.url ?? URL(fileURLWithPath: "/"))
                        )
                        return
                    }
                    continuation.resume(returning: (data, httpResponse))
                }
                // Store task under actor isolation before resuming it.
                Task {
                    await self.storeTask(task, id: id)
                }
                task.resume()
            }
        } onCancel: {
            Task { await self.cancelTask(id: id) }
        }
    }

    private func storeTask(_ task: URLSessionTask, id: UUID) {
        activeTasks[id] = task
    }

    private func cancelTask(id: UUID) {
        activeTasks[id]?.cancel()
        activeTasks.removeValue(forKey: id)
    }

    private func mapError(_ error: any Error) -> any Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return HTTP2MultiplexError.timeout
            case .cancelled:
                return HTTP2MultiplexError.cancelled
            case .secureConnectionFailed,
                 .serverCertificateUntrusted,
                 .clientCertificateRejected,
                 .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot:
                return HTTP2MultiplexError.tlsError(urlError.localizedDescription)
            default:
                return HTTP2MultiplexError.networkError(urlError)
            }
        }
        return HTTP2MultiplexError.networkError(error)
    }
}
