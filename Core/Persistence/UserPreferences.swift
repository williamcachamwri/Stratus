import Combine
import Foundation
import os.log

// MARK: - Preference Keys

private enum PreferenceKey {
    static let maxConcurrentUploads = "stratus.prefs.maxConcurrentUploads"
    static let maxConcurrentDownloads = "stratus.prefs.maxConcurrentDownloads"
    static let bandwidthLimitBPS = "stratus.prefs.bandwidthLimitBPS"
    static let notifyUploadComplete = "stratus.prefs.notifyUploadComplete"
    static let notifyUploadFailed = "stratus.prefs.notifyUploadFailed"
    static let cacheDirectoryBookmark = "stratus.prefs.cacheDirectoryBookmark"
    static let defaultProviderID = "stratus.prefs.defaultProviderID"
    static let autoStartUploads = "stratus.prefs.autoStartUploads"
}

// MARK: - UserPreferences

/// Typed, `@MainActor`-isolated preference store backed by `UserDefaults`.
///
/// SwiftUI views observe published properties directly:
/// ```swift
/// @EnvironmentObject var prefs: UserPreferences
/// ```
///
/// Each property uses a computed getter/setter pair so changes are
/// reflected immediately in `UserDefaults` and trigger `objectWillChange`.
@MainActor
public final class UserPreferences: ObservableObject {
    public static let shared = UserPreferences()

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "UserPreferences")

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults(in: defaults)
    }

    // MARK: - Upload / Download concurrency

    /// Maximum number of file uploads that may run simultaneously (1–32).
    public var maxConcurrentUploads: Int {
        get { clamped(defaults.integer(forKey: PreferenceKey.maxConcurrentUploads), in: 1 ... 32) }
        set {
            objectWillChange.send()
            defaults.set(clamped(newValue, in: 1 ... 32), forKey: PreferenceKey.maxConcurrentUploads)
        }
    }

    /// Maximum number of file downloads that may run simultaneously (1–32).
    public var maxConcurrentDownloads: Int {
        get { clamped(defaults.integer(forKey: PreferenceKey.maxConcurrentDownloads), in: 1 ... 32) }
        set {
            objectWillChange.send()
            defaults.set(clamped(newValue, in: 1 ... 32), forKey: PreferenceKey.maxConcurrentDownloads)
        }
    }

    // MARK: - Bandwidth

    /// Optional global bandwidth cap in bytes per second.
    /// `nil` means unlimited.
    public var bandwidthLimitBPS: Double? {
        get {
            let raw = defaults.double(forKey: PreferenceKey.bandwidthLimitBPS)
            // 0.0 is the "not set" sentinel registered as the default.
            return raw > 0 ? raw : nil
        }
        set {
            objectWillChange.send()
            defaults.set(newValue ?? 0.0, forKey: PreferenceKey.bandwidthLimitBPS)
        }
    }

    // MARK: - Notifications

    /// Whether to post a notification when an upload finishes successfully.
    public var notifyUploadComplete: Bool {
        get { defaults.bool(forKey: PreferenceKey.notifyUploadComplete) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: PreferenceKey.notifyUploadComplete)
        }
    }

    /// Whether to post a notification when an upload fails permanently.
    public var notifyUploadFailed: Bool {
        get { defaults.bool(forKey: PreferenceKey.notifyUploadFailed) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: PreferenceKey.notifyUploadFailed)
        }
    }

    // MARK: - Cache Directory

    /// Directory used to cache downloaded files and upload chunks.
    /// Backed by a security-scoped bookmark so it survives app relaunches
    /// even when the user has picked a custom location.
    public var cacheDirectory: URL {
        get {
            if let bookmarkData = defaults.data(forKey: PreferenceKey.cacheDirectoryBookmark) {
                var isStale = false
                if let url = try? URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ) {
                    if !isStale { return url }
                    // Bookmark is stale — refresh it and fall through to default.
                    logger.warning("Cache directory bookmark is stale, resetting to default")
                }
            }
            return Self.defaultCacheDirectory
        }
        set {
            objectWillChange.send()
            let bookmark = try? newValue.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            if let bookmark {
                defaults.set(bookmark, forKey: PreferenceKey.cacheDirectoryBookmark)
            } else {
                logger.warning("Could not create bookmark for cache directory \(newValue.path); preference not saved")
            }
        }
    }

    // MARK: - Provider

    /// The provider ID selected as the default upload destination, if any.
    public var defaultProviderID: String? {
        get {
            let raw = defaults.string(forKey: PreferenceKey.defaultProviderID)
            return raw?.isEmpty == false ? raw : nil
        }
        set {
            objectWillChange.send()
            defaults.set(newValue ?? "", forKey: PreferenceKey.defaultProviderID)
        }
    }

    // MARK: - Behaviour

    /// When `true`, uploads are enqueued and started automatically on file
    /// import; when `false` the user must start each upload manually.
    public var autoStartUploads: Bool {
        get { defaults.bool(forKey: PreferenceKey.autoStartUploads) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: PreferenceKey.autoStartUploads)
        }
    }

    // MARK: - Reset

    /// Removes all Stratus-managed keys from `UserDefaults` and re-registers
    /// the factory defaults.
    public func resetToDefaults() {
        let keys = [
            PreferenceKey.maxConcurrentUploads,
            PreferenceKey.maxConcurrentDownloads,
            PreferenceKey.bandwidthLimitBPS,
            PreferenceKey.notifyUploadComplete,
            PreferenceKey.notifyUploadFailed,
            PreferenceKey.cacheDirectoryBookmark,
            PreferenceKey.defaultProviderID,
            PreferenceKey.autoStartUploads,
        ]
        objectWillChange.send()
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        registerDefaults(in: defaults)
        logger.info("UserPreferences reset to defaults")
    }

    // MARK: - Private Helpers

    private static var defaultCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("com.stratus.cloudmanager", isDirectory: true)
    }

    private func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            PreferenceKey.maxConcurrentUploads: 3,
            PreferenceKey.maxConcurrentDownloads: 3,
            PreferenceKey.bandwidthLimitBPS: 0.0,
            PreferenceKey.notifyUploadComplete: true,
            PreferenceKey.notifyUploadFailed: true,
            PreferenceKey.defaultProviderID: "",
            PreferenceKey.autoStartUploads: true,
        ])
    }

    private func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
