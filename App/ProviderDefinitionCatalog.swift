import Foundation
import StratusCore

// MARK: - ProviderDefinition

public struct ProviderDefinition: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: String
    public let endpointTemplate: String?
    public let authURL: String?
    public let tokenURL: String?
    public let apiBaseURL: String?
    public let uploadBaseURL: String?
    public let supportsMultipartUpload: Bool?
    public let supportsResumableUpload: Bool?
    public let supportsParallelChunks: Bool?
    public let supportsTransferAcceleration: Bool?
    public let minimumChunkSizeBytes: Int?
    public let maximumChunkSizeBytes: Int?
    public let recommendedChunkSizeBytes: Int?
    public let chunkMultipleBytes: Int?
    public let defaultPort: Int?

    public var isOAuthProvider: Bool {
        authURL != nil && tokenURL != nil
    }

    public var requiresEndpointConfiguration: Bool {
        kind.contains("s3") || kind.contains("ssh") || kind.contains("webdav") || kind.contains("ftp")
    }

    public var capabilitiesText: String {
        var parts: [String] = []
        if supportsParallelChunks == true { parts.append("parallel chunks") }
        if supportsResumableUpload == true { parts.append("resume") }
        if supportsTransferAcceleration == true { parts.append("transfer acceleration") }
        if let recommendedChunkSizeBytes {
            parts.append("recommended chunk: \(ProviderDefinition.formatBytes(Int64(recommendedChunkSizeBytes)))")
        }
        return parts.isEmpty ? kind : parts.joined(separator: " · ")
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

private struct ProviderDefinitionFile: Codable, Sendable {
    let schemaVersion: Int
    let providers: [ProviderDefinition]
}

// MARK: - ProviderDefinitionCatalog

@MainActor
public final class ProviderDefinitionCatalog: ObservableObject {
    public static let shared = ProviderDefinitionCatalog()

    @Published public private(set) var providers: [ProviderDefinition]

    private init() {
        providers = Self.loadProviders()
    }

    public func definition(for id: String) -> ProviderDefinition? {
        providers.first { $0.id == id }
    }

    public func displayName(for id: String) -> String {
        definition(for: id)?.displayName ?? id
    }

    public func providerChoices() -> [ProviderChoice] {
        providers.map { definition in
            ProviderChoice(
                id: definition.id,
                title: definition.displayName,
                subtitle: definition.capabilitiesText,
                supportsParallelChunks: definition.supportsParallelChunks == true,
                supportsMounting: definition.kind != "ftp-file-transfer"
            )
        }
    }

    private static func loadProviders() -> [ProviderDefinition] {
        let decoder = JSONDecoder()
        var decodeFailures: [String] = []

        for url in candidateURLs() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                let file = try decoder.decode(ProviderDefinitionFile.self, from: data)
                return file.providers.sorted { $0.displayName < $1.displayName }
            } catch {
                decodeFailures.append("\(url.path): \(error.localizedDescription)")
            }
        }

        assertionFailure(
            "ProviderDefinitions.json was not found or could not be decoded. "
                + "Checked: \(candidateURLs().map(\.path).joined(separator: ", ")). "
                + "Failures: \(decodeFailures.joined(separator: " | "))"
        )
        return []
    }

    private static func candidateURLs() -> [URL] {
        var urls: [URL] = []

        appendResourceCandidates(from: Bundle.module, to: &urls)
        appendResourceCandidates(from: Bundle.main, to: &urls)

        if let executableURL = Bundle.main.executableURL {
            let appContentsURL = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            urls.append(appContentsURL.appendingPathComponent("Resources/Resources/ProviderDefinitions.json"))
            urls.append(appContentsURL.appendingPathComponent("Resources/ProviderDefinitions.json"))
        }

        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        urls.append(current.appendingPathComponent("Resources/ProviderDefinitions.json"))
        urls.append(current.deletingLastPathComponent().appendingPathComponent("Resources/ProviderDefinitions.json"))

        var seen = Set<String>()
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    private static func appendResourceCandidates(from bundle: Bundle, to urls: inout [URL]) {
        if let directURL = bundle.url(forResource: "ProviderDefinitions", withExtension: "json") {
            urls.append(directURL)
        }
        if let nestedURL = bundle.url(
            forResource: "ProviderDefinitions",
            withExtension: "json",
            subdirectory: "Resources"
        ) {
            urls.append(nestedURL)
        }
    }
}
