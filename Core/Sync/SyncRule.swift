import Foundation

// MARK: - Sync Rule

public struct SyncRule: Codable, Sendable, Identifiable {
    public let id: UUID
    public enum RuleType: String, Codable, Sendable { case include, exclude }
    public enum RuleScope: String, Codable, Sendable { case name, path, `extension`, size, date }

    public let type: RuleType
    public let pattern: String
    public let scope: RuleScope
    public let recursive: Bool
    public let isBuiltIn: Bool

    public init(id: UUID = UUID(), type: RuleType, pattern: String, scope: RuleScope, recursive: Bool = true, isBuiltIn: Bool = false) {
        self.id = id
        self.type = type
        self.pattern = pattern
        self.scope = scope
        self.recursive = recursive
        self.isBuiltIn = isBuiltIn
    }

    // MARK: - Built-in default exclude rules

    public static let defaultExcludes: [SyncRule] = [
        SyncRule(type: .exclude, pattern: ".DS_Store", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "Thumbs.db", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "desktop.ini", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: ".git", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "*.tmp", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "*.download", scope: .extension, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "*.crdownload", scope: .extension, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "*.part", scope: .extension, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "__MACOSX", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: ".Spotlight-V100", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: ".Trashes", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "node_modules", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: ".venv", scope: .name, isBuiltIn: true),
        SyncRule(type: .exclude, pattern: "__pycache__", scope: .name, isBuiltIn: true),
    ]

    // MARK: - Matching

    public func matches(path: String, name: String, fileExtension: String) -> Bool {
        switch scope {
        case .name:
            return fnmatch(pattern, name, 0) == 0
        case .path:
            return fnmatch(pattern, path, FNM_PATHNAME) == 0
        case .extension:
            let pat = pattern.hasPrefix("*.") ? String(pattern.dropFirst(2)) : pattern
            return fileExtension.lowercased() == pat.lowercased()
        case .size, .date:
            return false  // Handled by SyncEngine directly
        }
    }
}

// MARK: - Sync Pair

public struct SyncPair: Codable, Sendable, Identifiable {
    public let id: UUID
    public let localPath: URL
    public let remotePath: CloudPath
    public let accountID: String
    public var mode: SyncMode
    public var enabled: Bool
    public var rules: [SyncRule]
    public var conflictResolution: ConflictResolution
    public var lastSyncedAt: Date?

    public init(
        id: UUID = UUID(),
        localPath: URL,
        remotePath: CloudPath,
        accountID: String,
        mode: SyncMode = .bidirectional,
        enabled: Bool = true,
        rules: [SyncRule] = SyncRule.defaultExcludes,
        conflictResolution: ConflictResolution = .keepNewer
    ) {
        self.id = id
        self.localPath = localPath
        self.remotePath = remotePath
        self.accountID = accountID
        self.mode = mode
        self.enabled = enabled
        self.rules = rules
        self.conflictResolution = conflictResolution
    }
}

// MARK: - Sync Modes

public enum SyncMode: String, Codable, Sendable, CaseIterable {
    case oneWayUpload    = "one_way_upload"
    case oneWayDownload  = "one_way_download"
    case bidirectional   = "bidirectional"
    case mirror          = "mirror"
    case backup          = "backup"

    public var displayName: String {
        switch self {
        case .oneWayUpload:   return "Upload Only"
        case .oneWayDownload: return "Download Only"
        case .bidirectional:  return "Two-Way Sync"
        case .mirror:         return "Mirror (local → cloud)"
        case .backup:         return "Backup (keep all versions)"
        }
    }
}

// MARK: - Conflict Resolution

public enum ConflictResolution: String, Codable, Sendable, CaseIterable {
    case keepLocal   = "keep_local"
    case keepRemote  = "keep_remote"
    case keepNewer   = "keep_newer"
    case keepLarger  = "keep_larger"
    case keepBoth    = "keep_both"
    case askUser     = "ask_user"

    public var displayName: String {
        switch self {
        case .keepLocal:  return "Keep Local"
        case .keepRemote: return "Keep Remote"
        case .keepNewer:  return "Keep Newer"
        case .keepLarger: return "Keep Larger"
        case .keepBoth:   return "Keep Both"
        case .askUser:    return "Ask Me"
        }
    }
}

// MARK: - Sync Conflict

public struct SyncConflict: Sendable, Identifiable {
    public let id: UUID
    public let pairID: UUID
    public let localURL: URL
    public let remotePath: CloudPath
    public let localModDate: Date
    public let remoteModDate: Date
    public let localSize: Int64
    public let remoteSize: Int64
    public let detectedAt: Date

    public init(pairID: UUID, localURL: URL, remotePath: CloudPath,
                localModDate: Date, remoteModDate: Date, localSize: Int64, remoteSize: Int64) {
        self.id = UUID()
        self.pairID = pairID
        self.localURL = localURL
        self.remotePath = remotePath
        self.localModDate = localModDate
        self.remoteModDate = remoteModDate
        self.localSize = localSize
        self.remoteSize = remoteSize
        self.detectedAt = Date()
    }
}
