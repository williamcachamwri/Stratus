import Foundation
import os.log

// MARK: - OfflineCacheError

public enum OfflineCacheError: Error, Sendable {
    case fileNotCached(CloudPath)
    case evictionFailed(underlying: any Error)
    case pinFailed(path: CloudPath, underlying: any Error)
    case storageUnavailable
}

// MARK: - OfflineCacheManager

/// Manages on-demand file caching and offline availability.
///
/// "Pinned" files are guaranteed to be present in `LocalCacheStore` even when
/// the device is offline.  Unpinned files remain in the cache until eviction
/// pressure removes them.  All state is held in-actor; coordination with the
/// underlying `LocalCacheStore` is done via async calls so the two actors never
/// create a lock-order dependency.
public actor OfflineCacheManager {

    // MARK: - Types

    /// Identifies a cached item by account + path pair.
    private struct CacheKey: Hashable, Sendable {
        let accountID: String
        let path: CloudPath
    }

    // MARK: - Dependencies

    private let cacheStore: LocalCacheStore
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "OfflineCacheManager")

    // MARK: - State

    /// Paths explicitly pinned for offline use.
    private var pinnedKeys: Set<CacheKey> = []

    // MARK: - Init

    public init(cacheStore: LocalCacheStore) {
        self.cacheStore = cacheStore
    }

    // MARK: - Pin / Unpin

    /// Marks `path` as required offline and ensures it is present in the cache.
    ///
    /// If the file is already cached this is a no-op (besides recording the pin).
    /// Callers are responsible for supplying a `fileURL` when the file must be
    /// fetched first; call `LocalCacheStore.cacheFile` before calling this if
    /// the file is not yet local.
    public func pin(path: CloudPath, account: CloudAccount) async throws {
        let key = CacheKey(accountID: account.id, path: path)

        // Verify the file exists in the cache before committing the pin.
        guard await cacheStore.cachedURL(forPath: path, account: account) != nil else {
            throw OfflineCacheError.fileNotCached(path)
        }

        pinnedKeys.insert(key)
        logger.info("Pinned \(path, privacy: .public) for account \(account.id, privacy: .public)")
    }

    /// Removes the offline pin for `path`.  The file remains in cache but is
    /// now eligible for eviction under memory pressure.
    public func unpin(path: CloudPath, account: CloudAccount) async {
        let key = CacheKey(accountID: account.id, path: path)
        pinnedKeys.remove(key)
        logger.info("Unpinned \(path, privacy: .public) for account \(account.id, privacy: .public)")
    }

    // MARK: - Query

    /// Returns `true` when `path` is pinned *and* its cached file still exists
    /// on disk.  A pinned entry whose file was externally deleted reports `false`.
    public func isAvailableOffline(path: CloudPath, account: CloudAccount) async -> Bool {
        let key = CacheKey(accountID: account.id, path: path)
        guard pinnedKeys.contains(key) else { return false }
        // Confirm the backing file is still present.
        return await cacheStore.cachedURL(forPath: path, account: account) != nil
    }

    // MARK: - Eviction

    /// Evicts unpinned cached files, oldest-first, until at least
    /// `targetFreeBytes` of additional space has been reclaimed.
    ///
    /// Pinned files are never removed.  Throws if the underlying store reports
    /// an error while removing a file.
    public func evictOldFiles(targetFreeBytes: Int64) async throws {
        logger.info("Eviction requested: target \(targetFreeBytes) bytes free")

        let reclaimed = try await cacheStore.evictUnpinned(
            pinnedKeys: pinnedKeys.map { LookupKey(accountID: $0.accountID, path: $0.path) },
            targetFreeBytes: targetFreeBytes
        )

        logger.info("Eviction complete: reclaimed \(reclaimed) bytes")
    }
}

// MARK: - LookupKey (Sendable bridge for LocalCacheStore)

/// A Sendable value type carrying the same identity as `OfflineCacheManager.CacheKey`
/// so it can be passed across actor boundaries without exposing the private nested type.
public struct LookupKey: Hashable, Sendable {
    public let accountID: String
    public let path: CloudPath

    public init(accountID: String, path: CloudPath) {
        self.accountID = accountID
        self.path = path
    }
}
