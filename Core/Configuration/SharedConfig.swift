import Foundation

// MARK: - SharedConfig

/// Loads Stratus configuration variables from `shared/*.config` files and
/// matching process environment variables.
///
/// Priority order:
/// 1. Process environment variables.
/// 2. `shared/*.local.config` files for developer/local secrets.
/// 3. Checked-in `shared/*.config` template defaults.
///
/// `.config` syntax is intentionally simple: one `KEY=value` per line, with
/// `#` comments and blank lines ignored. Values are not evaluated as shell.
public enum SharedConfig {
    public static func string(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        return loadConfigValues()[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    public static func string(_ suffix: String, providerID: String) -> String? {
        string(key(suffix, providerID: providerID))
    }

    public static func bool(_ suffix: String, providerID: String, default defaultValue: Bool = false) -> Bool {
        guard let value = string(suffix, providerID: providerID) else { return defaultValue }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on": return true
        case "0", "false", "no", "n", "off": return false
        default: return defaultValue
        }
    }

    public static func key(_ suffix: String, providerID: String) -> String {
        "STRATUS_\(prefix(for: providerID))_\(suffix)"
    }

    private static func prefix(for providerID: String) -> String {
        providerID
            .uppercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "_"
            }
            .reduce(into: "") { partial, character in
                if character == "_", partial.last == "_" { return }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func loadConfigValues() -> [String: String] {
        var result: [String: String] = [:]
        for url in configFiles() {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equal = trimmed.firstIndex(of: "=") else {
                    continue
                }
                let key = String(trimmed[..<equal]).trimmingCharacters(in: .whitespacesAndNewlines)
                let valueStart = trimmed.index(after: equal)
                let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { continue }
                result[key] = unquote(value)
            }
        }
        return result
    }

    private static func configFiles() -> [URL] {
        let directories = configDirectories()
        let localFiles = directories.flatMap { directory in
            files(in: directory, matching: ".local.config")
        }
        let defaultFiles = directories.flatMap { directory in
            files(in: directory, matching: ".config").filter { !$0.lastPathComponent.hasSuffix(".local.config") }
        }
        return defaultFiles + localFiles
    }

    private static func configDirectories() -> [URL] {
        var urls: [URL] = []
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["STRATUS_SHARED_CONFIG_DIR"], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        // Current working directory (and one level up) — works when cwd is the project root.
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        urls.append(current.appendingPathComponent("shared", isDirectory: true))
        urls.append(current.deletingLastPathComponent().appendingPathComponent("shared", isDirectory: true))

        // Walk upward from the executable — handles running the raw binary from
        // .build/debug/ or .build/release/ where cwd-relative search misses the root.
        if let execURL = Bundle.main.executableURL {
            var dir = execURL.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = dir.appendingPathComponent("shared", isDirectory: true)
                if fileManager.fileExists(atPath: candidate.path) {
                    urls.append(candidate)
                    break
                }
                let parent = dir.deletingLastPathComponent()
                guard parent.path != dir.path else { break }
                dir = parent
            }
        }

        // .app bundle Resources/shared — used when config is bundled for distribution.
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("shared", isDirectory: true))
            urls.append(resourceURL.appendingPathComponent("Resources/shared", isDirectory: true))
        }

        var seen: Set<String> = []
        return urls.filter { url in
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return fileManager.fileExists(atPath: path)
        }
    }

    private static func files(in directory: URL, matching suffix: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if value.hasPrefix("\"") && value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("'") && value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
