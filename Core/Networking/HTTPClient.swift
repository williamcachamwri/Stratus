import Foundation
import Network
import os.log

// MARK: - HTTP Response

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    public var isSuccess: Bool { (200...299).contains(statusCode) }
    public var isRetryable: Bool { [429, 500, 502, 503, 504].contains(statusCode) }
    public var isNonRetryable: Bool { [400, 401, 403, 404, 409].contains(statusCode) }

    public func retryAfter() -> TimeInterval? {
        guard let value = headers["Retry-After"] ?? headers["retry-after"] else { return nil }
        return TimeInterval(value)
    }
}

public enum HTTPMethod: String, Sendable {
    case GET, POST, PUT, DELETE, HEAD, PATCH
}

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: HTTPMethod
    public var headers: [String: String]
    public var body: Data?
    public var timeoutInterval: TimeInterval

    public init(
        url: URL,
        method: HTTPMethod = .GET,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutInterval: TimeInterval = 30
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public enum HTTPClientError: Error, Sendable {
    case invalidURL(String)
    case requestFailed(statusCode: Int, data: Data)
    case networkError(any Error)
    case decodingError(any Error)
    case timeout
    case cancelled
    case tlsError(String)
    case redirectLoop
}

// MARK: - HTTPClient Actor

public actor HTTPClient {
    private let session: URLSession
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "HTTPClient")

    public static let shared = HTTPClient()

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? HTTPClient.makeDefaultConfiguration()
        self.session = URLSession(configuration: config)
    }

    private static func makeDefaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 0  // unlimited for large files
        config.waitsForConnectivity = true
        config.allowsCellularAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        // Force HTTP/2 where available
        config.httpShouldUsePipelining = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return config
    }

    // MARK: - Core Request Methods

    public func data(for request: HTTPRequest) async throws -> HTTPResponse {
        let urlRequest = try makeURLRequest(from: request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return try parseResponse(data: data, response: response)
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    public func upload(request: HTTPRequest, from bodyData: Data) async throws -> HTTPResponse {
        var urlRequest = try makeURLRequest(from: request)
        urlRequest.httpBody = bodyData
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return try parseResponse(data: data, response: response)
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    public func upload(request: HTTPRequest, fromFile fileURL: URL) async throws -> HTTPResponse {
        let urlRequest = try makeURLRequest(from: request)
        do {
            let (data, response) = try await session.upload(for: urlRequest, fromFile: fileURL)
            return try parseResponse(data: data, response: response)
        } catch let error as URLError {
            throw mapURLError(error)
        }
    }

    // Streaming upload with progress reporting
    public func uploadStream(
        request: HTTPRequest,
        stream: InputStream,
        contentLength: Int64,
        progressHandler: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws -> HTTPResponse {
        let urlRequest = try makeURLRequest(from: request)
        let delegate = UploadProgressDelegate(
            contentLength: contentLength,
            progressHandler: progressHandler
        )
        let sessionWithDelegate = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { sessionWithDelegate.invalidateAndCancel() }

        let task = sessionWithDelegate.uploadTask(withStreamedRequest: urlRequest)
        delegate.inputStream = stream
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            task.resume()
        }
    }

    // JSON convenience
    public func json<T: Decodable & Sendable>(
        for request: HTTPRequest,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let response = try await data(for: request)
        guard response.isSuccess else {
            throw HTTPClientError.requestFailed(statusCode: response.statusCode, data: response.data)
        }
        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            throw HTTPClientError.decodingError(error)
        }
    }

    // MARK: - Private Helpers

    private func makeURLRequest(from request: HTTPRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = request.timeoutInterval
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let body = request.body {
            urlRequest.httpBody = body
        }
        return urlRequest
    }

    private func parseResponse(data: Data, response: URLResponse) throws -> HTTPResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPClientError.networkError(URLError(.badServerResponse))
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        logger.debug("HTTP \(httpResponse.statusCode) \(httpResponse.url?.absoluteString ?? "")")
        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            data: data
        )
    }

    private func mapURLError(_ error: URLError) -> HTTPClientError {
        switch error.code {
        case .timedOut: return .timeout
        case .cancelled: return .cancelled
        case .secureConnectionFailed, .serverCertificateUntrusted, .clientCertificateRejected:
            return .tlsError(error.localizedDescription)
        case .redirectToNonExistentLocation, .httpTooManyRedirects:
            return .redirectLoop
        default:
            return .networkError(error)
        }
    }
}

// MARK: - Upload Progress Delegate

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let contentLength: Int64
    let progressHandler: @Sendable (Int64, Int64) -> Void
    var continuation: CheckedContinuation<HTTPResponse, any Error>?
    var inputStream: InputStream?
    private var responseData = Data()
    private var response: HTTPURLResponse?

    init(contentLength: Int64, progressHandler: @Sendable @escaping (Int64, Int64) -> Void) {
        self.contentLength = contentLength
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progressHandler(totalBytesSent, contentLength)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            continuation?.resume(throwing: HTTPClientError.networkError(error))
        } else if let httpResponse = response {
            let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
                if let k = pair.key as? String, let v = pair.value as? String {
                    dict[k] = v
                }
            }
            continuation?.resume(returning: HTTPResponse(
                statusCode: httpResponse.statusCode,
                headers: headers,
                data: responseData
            ))
        } else {
            continuation?.resume(throwing: HTTPClientError.networkError(URLError(.badServerResponse)))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping @Sendable (InputStream?) -> Void) {
        completionHandler(inputStream)
    }
}

// MARK: - Network Reachability

public actor NetworkReachability {
    public static let shared = NetworkReachability()
    private let monitor = NWPathMonitor()
    private var currentPath: NWPath?
    private var continuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public var isAvailable: Bool {
        currentPath?.status == .satisfied
    }

    public var isExpensive: Bool {
        currentPath?.isExpensive ?? false
    }

    public var isConstrained: Bool {
        currentPath?.isConstrained ?? false
    }

    private init() {
        let queue = DispatchQueue(label: "com.stratus.networkmonitor")
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.updatePath(path)
            }
        }
        monitor.start(queue: queue)
    }

    private func updatePath(_ path: NWPath) {
        currentPath = path
        let available = path.status == .satisfied
        for continuation in continuations.values {
            continuation.yield(available)
        }
    }

    public var statusStream: AsyncStream<Bool> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.removeContinuation(id: id)
                }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
