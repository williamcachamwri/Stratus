// Logger.swift
// StratusCore — Structured logging wrapper around os.Logger
//
// Subsystem: "com.stratus.cloudmanager"
// Categories: upload, download, sync, provider, networking, encryption
//
// Swift 6: actor-isolated, no force-unwraps, typed errors.

import Foundation
import os.log

// MARK: - Log Category

/// The functional domain that produced a log entry.
public enum LogCategory: String, Sendable, CaseIterable {
    case upload
    case download
    case sync
    case provider
    case networking
    case encryption
    case general
}

// MARK: - Log Level

public enum LogLevel: String, Sendable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case notice = "NOTICE"
    case warning = "WARNING"
    case error = "ERROR"
    case fault = "FAULT"

    /// Raw order for Comparable conformance
    private var order: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        case .fault: 5
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.order < rhs.order
    }
}

// MARK: - Redaction Patterns

private enum RedactionPattern {
    /// Patterns whose captured group is replaced with <redacted>
    static let tokenPatterns: [String] = [
        #"(bearer\s+)\S+"#,
        #"(token[=:]\s*)\S+"#,
        #"(password[=:]\s*)\S+"#,
        #"(secret[=:]\s*)\S+"#,
        #"(Authorization:\s*)\S+"#,
        #"(api[-_]?key[=:]\s*)\S+"#,
    ]

    static let compiled: [NSRegularExpression] = tokenPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: .caseInsensitive)
    }
}

// MARK: - DiagnosticLogger

/// Actor-isolated structured logger.
///
/// All `os.Logger` instances are created once per category to satisfy Swift 6's
/// requirement that `OSLog`-backed objects are sendable across isolation
/// boundaries — `os.Logger` is itself `Sendable`.
public actor DiagnosticLogger {
    // MARK: Singleton

    public static let shared = DiagnosticLogger()

    // MARK: Private State

    private let subsystem = "com.stratus.cloudmanager"
    private var minimumLevel: LogLevel = .debug

    /// Pre-built logger per category — keyed by raw value for O(1) lookup.
    private var loggers: [String: os.Logger] = [:]

    // MARK: Init

    private init() {
        for category in LogCategory.allCases {
            loggers[category.rawValue] = os.Logger(
                subsystem: "com.stratus.cloudmanager",
                category: category.rawValue
            )
        }
    }

    // MARK: Configuration

    /// Sets the minimum log level; entries below this level are silently dropped.
    public func setMinimumLevel(_ level: LogLevel) {
        minimumLevel = level
    }

    // MARK: Core Logging

    /// Logs a message with an explicit level and category.
    public func log(
        level: LogLevel,
        category: LogCategory,
        message: String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        guard level >= minimumLevel else { return }

        let redacted = redact(message)
        let location = "\(file):\(line) \(function)"
        let logger = loggers[category.rawValue] ?? os.Logger(
            subsystem: subsystem,
            category: category.rawValue
        )

        switch level {
        case .debug:
            logger.debug("[\(location, privacy: .public)] \(redacted, privacy: .public)")
        case .info:
            logger.info("[\(location, privacy: .public)] \(redacted, privacy: .public)")
        case .notice:
            logger.notice("[\(location, privacy: .public)] \(redacted, privacy: .public)")
        case .warning:
            logger.warning("[\(location, privacy: .public)] \(redacted, privacy: .public)")
        case .error:
            logger.error("[\(location, privacy: .public)] \(redacted, privacy: .public)")
        case .fault:
            logger.fault("[\(location, privacy: .public)] \(redacted, privacy: .public)")
        }
    }

    // MARK: Convenience Methods

    public func debug(
        _ message: String,
        category: LogCategory = .general,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: .debug,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }

    public func info(
        _ message: String,
        category: LogCategory = .general,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: .info,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }

    public func notice(
        _ message: String,
        category: LogCategory = .general,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: .notice,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }

    public func warning(
        _ message: String,
        category: LogCategory = .general,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: .warning,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }

    public func error(
        _ message: String,
        category: LogCategory = .general,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: .error,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }

    public func fault(
        _ message: String,
        category: LogCategory = .general,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(
            level: .fault,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }

    // MARK: - Redaction

    /// Replaces credential/token values in a message with `<redacted>`.
    private func redact(_ message: String) -> String {
        let mutableMsg = NSMutableString(string: message)
        let fullRange = NSRange(message.startIndex..., in: message)

        for regex in RedactionPattern.compiled {
            // Replace the second capture group (the sensitive value) while
            // keeping the key/prefix intact.
            regex.replaceMatches(
                in: mutableMsg,
                range: fullRange,
                withTemplate: "$1<redacted>"
            )
        }

        return mutableMsg as String
    }
}

// MARK: - Global Convenience (non-isolated call sites)

/// Fire-and-forget helper for call sites that cannot await the actor.
/// Intended for use inside synchronous contexts only; prefer the async actor
/// methods from async contexts.
public func stratusLog(
    _ message: String,
    level: LogLevel = .info,
    category: LogCategory = .general,
    file: String = #fileID,
    function: String = #function,
    line: Int = #line
) {
    Task {
        await DiagnosticLogger.shared.log(
            level: level,
            category: category,
            message: message,
            file: file,
            function: function,
            line: line
        )
    }
}
