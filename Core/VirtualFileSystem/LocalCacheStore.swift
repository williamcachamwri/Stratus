import Foundation
import os.log

// MARK: - LocalCacheStoreError

public enum LocalCacheStoreError: Error, Sendable {
    case cacheDirectoryUnavailable(URL)
    case fileTooLargeForCache(size: Int64, limit: Int64)
    case writeFailure(URL, underlying: any Error)
    case removalFailure(URL, underlying: any Error)
    case statFailure(URL, underlying: any Error)
}

// MARK: - LocalCacheStore

/// An LRU cache that stores cloud files on local disk.
///
/// Every cached file is placed in `cacheDirectory` under a deterministic
/// subdirectory derived from `accountID/encodedPath`.  A lightweight
/// `CacheEntry` record tracks file size and last-access time so the actor
/// can answer size queries and perform LRU eviction without touching the
/// filesystem for every operation.
///
/// Default capacity: 10 GiB.  Pass a custom `sizeLimitBytes` to `init` to
/// override.
public actor LocalCacheStore {

    // MARK: - Configuration

    public static let defaultSizeLimitBytes: Int64 = 10 * 1024 * 1024 * 1024  // 10 GiB

    // MARK: - Types

    private struct CacheEntry: Sendable {
        let url: URL
        let size: Int64
        var lastAccessedAt: Date
        let cachedAt: Date
    }

    private struct EntryKey: Hashable, Sendable {
        let accountID: String
        let path: CloudPath
    }

    // MARK: - State

    private var entries: [EntryKey: CacheEntry] = [:]
    private var totalBytes: Int64 = 0
    private let sizeLimitBytes: Int64
    private let cacheDirectory: URL
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "LocalCacheStore")

    // MARK: - Init

    public init(
        cacheDirectory: URL,
        sizeLimitBytes: Int64 = LocalCacheStore.defaultSizeLimitBytes
    ) throws {
        self.cacheDirectory = cacheDirectory
        self.sizeLimitBytes = sizeLimitBytes
        try FileManager.default.createDirectory(at: cacheDirectory,
                                                withIntermediateDirectories: true)
    }

    // MARK: - Cache a file

    /// Copies the file at `url` into the cache, associating it with `forPath`
    /// and `account`.  If the file already exists in the cache it is
    /// overwritten.  Evicts LRU entries automatically if the new file would
    /// exceed `sizeLimitBytes`.
    public func cacheFile(url: URL, forPath path: CloudPath, account: CloudAccount) async throws {
        let fileSize = try fileSize(at: url)

        guard fileSize <= sizeLimitBytes else {
            throw LocalCacheStoreError.fileTooLargeForCache(size: fileSize, limit: sizeLimitBytes)
        }

        // Evict until there is room.
        try await makeRoom(for: fileSize)

        let destination = cacheURL(forPath: path, accountID: account.id)
        let dir = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            // Atomic replace: if a prior version exists, remove it first.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw LocalCacheStoreError.writeFailure(destination, underlying: error)
        }

        let key = EntryKey(accountID: account.id, path: path)
        if let existing = entries[key] {
            totalBytes -= existing.size
        }
        entries[key] = CacheEntry(
            url: destination,
            size: fileSize,
            lastAccessedAt: Date(),
            cachedAt: Date()
        )
        totalBytes += fileSize

        logger.debug("Cached \(path, privacy: .public) (\(fileSize) bytes) for account \(account.id, privacy: .public)")
    }

    // MARK: - Retrieve

    /// Returns the local `URL` for a previously cached file, or `nil` if it is
    /// not present.  Bumps the LRU access timestamp on hit.
    public func cachedURL(forPath path: CloudPath, account: CloudAccount) async -> URL? {
        let key = EntryKey(accountID: account.id, path: path)
        guard var entry = entries[key] else { return nil }

        // Verify the file still exists (could have been cleaned by the OS).
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            totalBytes -= entry.size
            entries.removeValue(forKey: key)
            return nil
        }

        entry.lastAccessedAt = Date()
        entries[key] = entry
        return entry.url
    }

    // MARK: - Remove

    /// Explicitly removes a single cached file.
    public func removeFromCache(path: CloudPath, account: CloudAccount) async throws {
        let key = EntryKey(accountID: account.id, path: path)
        guard let entry = entries[key] else { return }

        do {
            if FileManager.default.fileExists(atPath: entry.url.path) {
                try FileManager.default.removeItem(at: entry.url)
            }
        } catch {
            throw LocalCacheStoreError.removalFailure(entry.url, underlying: error)
        }

        totalBytes -= entry.size
        entries.removeValue(forKey: key)
        logger.debug("Removed cache entry for \(path, privacy: .public) (account \(account.id, privacy: .public))")
    }

    // MARK: - Size

    /// Returns the total number of bytes currently occupied by cached files.
    public func totalCacheSize() async throws -> Int64 {
        totalBytes
    }

    // MARK: - Expire old entries

    /// Removes all cached files whose `cachedAt` timestamp is older than `date`.
    public func clearExpired(olderThan date: Date) async throws {
        let expiredKeys = entries.filter { $0.value.cachedAt < date }.map(\.key)
        for key in expiredKeys {
            guard let entry = entries[key] else { continue }
            do {
                if FileManager.default.fileExists(atPath: entry.url.path) {
                    try FileManager.default.removeItem(at: entry.url)
                }
            } catch {
                throw LocalCacheStoreError.removalFailure(entry.url, underlying: error)
            }
            totalBytes -= entry.size
            entries.removeValue(forKey: key)
        }
        logger.info("Cleared \(expiredKeys.count) expired cache entries")
    }

    // MARK: - Evict unpinned (called by OfflineCacheManager)

    /// Removes unpinned LRU entries until `targetFreeBytes` bytes have been
    /// reclaimed.  Returns the total bytes actually freed.
    ///
    /// Entries whose keys appear in `pinnedKeys` are skipped.
    @discardableResult
    public func evictUnpinned(
        pinnedKeys pinned: [LookupKey],
        targetFreeBytes: Int64
    ) async throws -> Int64 {
        let pinnedSet = Set(pinned.map { EntryKey(accountID: $0.accountID, path: $0.path) })

        // Sort by last access ascending (oldest first).
        let candidates = entries
            .filter { !pinnedSet.contains($0.key) }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }

        var freed: Int64 = 0
        for (key, entry) in candidates {
            guard freed < targetFreeBytes else { break }
            do {
                if FileManager.default.fileExists(atPath: entry.url.path) {
                    try FileManager.default.removeItem(at: entry.url)
                }
            } catch {
                throw LocalCacheStoreError.removalFailure(entry.url, underlying: error)
            }
            freed += entry.size
            totalBytes -= entry.size
            entries.removeValue(forKey: key)
        }
        return freed
    }

    // MARK: - Private helpers

    private func cacheURL(forPath path: CloudPath, accountID: String) -> URL {
        // Encode the path into a safe filename component.
        let encoded = path.path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path.path
        return cacheDirectory
            .appendingPathComponent(accountID, isDirectory: true)
            .appendingPathComponent(encoded)
    }

    private func fileSize(at url: URL) throws -> Int64 {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.size] as? Int64) ?? 0
        } catch {
            throw LocalCacheStoreError.statFailure(url, underlying: error)
        }
    }

    /// Evict LRU unpinned entries until there is capacity for `needed` bytes.
    private func makeRoom(for needed: Int64) async throws {
        guard totalBytes + needed > sizeLimitBytes else { return }
        let excess = totalBytes + needed - sizeLimitBytes
        // Evict without pinning constraints — no external pin list available here.
        try await evictUnpinned(pinnedKeys: [], targetFreeBytes: excess)
    }
}
