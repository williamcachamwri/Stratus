import Foundation
import Citadel
import os.log

// MARK: - SFTPCredentials

public struct SFTPCredentials: Sendable {
    /// Password authentication. Mutually exclusive with `privateKey`.
    public let password: String?
    /// PEM-encoded private key. Mutually exclusive with `password`.
    public let privateKey: String?

    public init(password: String? = nil, privateKey: String? = nil) {
        self.password = password
        self.privateKey = privateKey
    }
}

// MARK: - SFTPSession

public struct SFTPSession: Sendable {
    public let id: UUID
    public let host: String
    public let port: Int
    public let username: String

    // The underlying Citadel SFTP client.
    // @unchecked Sendable: SFTPClient is from Citadel (NIO-backed); it is designed
    // for concurrent use via its own internal synchronisation on the NIO EventLoop.
    let client: SFTPClient

    public init(id: UUID = UUID(), host: String, port: Int, username: String, client: SFTPClient) {
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.client = client
    }
}

// MARK: - Pool Key

private struct PoolKey: Hashable {
    let host: String
    let port: Int
    let username: String
}

// MARK: - SFTPConnectionPool
// Maintains a pool of active SFTP sessions (max 4 per server) for connection reuse.
// Callers acquire a session before transfer and release it when done.

public actor SFTPConnectionPool {

    public static let shared = SFTPConnectionPool()

    private static let maxPerServer = 4

    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "SFTPConnectionPool")

    /// Available (idle) sessions per server key
    private var available: [PoolKey: [SFTPSession]] = [:]

    /// Count of sessions currently checked out per server key
    private var inUseCount: [PoolKey: Int] = [:]

    private init() {}

    // MARK: - Acquire

    /// Returns an idle session from the pool, or creates a new one if the pool has room.
    /// Throws `SFTPPoolError.poolExhausted` when all 4 slots are in use.
    public func acquire(
        host: String,
        port: Int,
        username: String,
        credentials: SFTPCredentials
    ) async throws -> SFTPSession {
        let key = PoolKey(host: host, port: port, username: username)
        let currentInUse = inUseCount[key, default: 0]
        let idleCount = available[key]?.count ?? 0

        // Return an idle session from the pool if one exists
        if var idle = available[key], !idle.isEmpty {
            let session = idle.removeLast()
            available[key] = idle
            inUseCount[key] = currentInUse + 1
            logger.debug("Reusing SFTP session \(session.id) for \(host):\(port)")
            return session
        }

        // All connections are in use — reject if at cap
        if currentInUse + idleCount >= Self.maxPerServer {
            throw SFTPPoolError.poolExhausted(host: host, port: port, max: Self.maxPerServer)
        }

        // Create a new connection
        logger.info("Creating new SFTP connection to \(host):\(port) (\(currentInUse + 1)/\(Self.maxPerServer))")
        let client = try await makeClient(host: host, port: port, username: username, credentials: credentials)
        let session = SFTPSession(id: UUID(), host: host, port: port, username: username, client: client)
        inUseCount[key] = currentInUse + 1
        return session
    }

    // MARK: - Release

    /// Returns a session to the idle pool so it can be reused.
    public func release(session: SFTPSession) {
        let key = PoolKey(host: session.host, port: session.port, username: session.username)
        let currentInUse = max(0, inUseCount[key, default: 0] - 1)
        inUseCount[key] = currentInUse

        if available[key] == nil {
            available[key] = []
        }
        available[key]?.append(session)
        logger.debug("Released SFTP session \(session.id) back to pool for \(session.host):\(session.port)")
    }

    // MARK: - Evict

    /// Closes and removes all idle sessions for a given server.
    public func evict(host: String, port: Int, username: String) async {
        let key = PoolKey(host: host, port: port, username: username)
        let sessions = available[key] ?? []
        available.removeValue(forKey: key)
        for session in sessions {
            try? await session.client.close()
        }
        logger.info("Evicted \(sessions.count) idle SFTP sessions for \(host):\(port)")
    }

    // MARK: - Private

    private func makeClient(
        host: String,
        port: Int,
        username: String,
        credentials: SFTPCredentials
    ) async throws -> SFTPClient {
        let authMethod: SSHAuthenticationMethod
        if let key = credentials.privateKey {
            // Citadel expects raw PEM data; fall back to password-based if key parsing fails
            _ = key  // Simplified: production would parse the PEM and use .privateKey(...)
            authMethod = .passwordBased(username: username, password: "")
        } else if let password = credentials.password {
            authMethod = .passwordBased(username: username, password: password)
        } else {
            throw SFTPPoolError.missingCredentials
        }

        let sshClient = try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: authMethod,
            hostKeyValidator: .acceptAnything(),  // Production: validate against known_hosts
            reconnect: .never
        )
        return try await sshClient.openSFTP()
    }
}

// MARK: - SFTPPoolError

public enum SFTPPoolError: Error, Sendable {
    case poolExhausted(host: String, port: Int, max: Int)
    case missingCredentials
    case connectionFailed(String)
}
