import Foundation
import os.log

// MARK: - ConflictResolver

public actor ConflictResolver {
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ConflictResolver")

    public init() {}

    // MARK: - Resolve

    public func resolve(
        conflict: SyncConflict,
        resolution: ConflictResolution,
        provider: any CloudProvider,
        account: CloudAccount
    ) async throws -> ResolvedAction {
        switch resolution {
        case .keepLocal:
            return .upload(conflict.localURL, conflict.remotePath)

        case .keepRemote:
            return .download(conflict.remotePath, conflict.localURL)

        case .keepNewer:
            if conflict.localModDate >= conflict.remoteModDate {
                logger.debug("Conflict resolved: local is newer for \(conflict.localURL.lastPathComponent)")
                return .upload(conflict.localURL, conflict.remotePath)
            } else {
                logger.debug("Conflict resolved: remote is newer for \(conflict.localURL.lastPathComponent)")
                return .download(conflict.remotePath, conflict.localURL)
            }

        case .keepLarger:
            if conflict.localSize >= conflict.remoteSize {
                return .upload(conflict.localURL, conflict.remotePath)
            } else {
                return .download(conflict.remotePath, conflict.localURL)
            }

        case .keepBoth:
            let conflictURL = makeConflictCopy(of: conflict.localURL, date: conflict.localModDate)
            return .keepBoth(uploadOriginal: conflict.localURL, remotePath: conflict.remotePath,
                              downloadTo: conflict.localURL, conflictCopyURL: conflictURL)

        case .askUser:
            return .needsUserDecision(conflict)
        }
    }

    // MARK: - Private Helpers

    private func makeConflictCopy(of url: URL, date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let timestamp = formatter.string(from: date)
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let conflictName = ext.isEmpty
            ? "\(name) (conflict \(timestamp))"
            : "\(name) (conflict \(timestamp)).\(ext)"
        return url.deletingLastPathComponent().appendingPathComponent(conflictName)
    }
}

// MARK: - Resolved Action

public enum ResolvedAction: Sendable {
    case upload(URL, CloudPath)
    case download(CloudPath, URL)
    case keepBoth(uploadOriginal: URL, remotePath: CloudPath, downloadTo: URL, conflictCopyURL: URL)
    case needsUserDecision(SyncConflict)
    case skip
}
