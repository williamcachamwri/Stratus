import Foundation
import os.log

// MARK: - ProxyConfig

/// Represents a complete proxy configuration.
///
/// `ProxyConfig.system` reads macOS/iOS system proxy settings via
/// `CFNetworkCopySystemProxySettings`.  Callers may override individual
/// proxy types with custom values before applying the config to a
/// `URLSessionConfiguration`.
public struct ProxyConfig: Codable, Sendable {
    // MARK: - Proxy Entry

    public struct ProxyEntry: Codable, Sendable, Equatable {
        public let host: String
        public let port: Int
        /// Optional username for authenticated proxies.
        public let username: String?
        /// Optional password for authenticated proxies (never logged).
        public let password: String?

        public init(host: String, port: Int, username: String? = nil, password: String? = nil) {
            self.host = host
            self.port = port
            self.username = username
            self.password = password
        }
    }

    // MARK: - Stored Properties

    /// HTTP proxy override.  `nil` means use the system setting (if any).
    public var httpProxy: ProxyEntry?
    /// HTTPS proxy override.
    public var httpsProxy: ProxyEntry?
    /// SOCKS5 proxy override.
    public var socks5Proxy: ProxyEntry?
    /// Hosts that bypass all proxy settings (comma-separated patterns accepted
    /// by URLSession, e.g. "*.internal, localhost").
    public var noProxyHosts: [String]

    public init(
        httpProxy: ProxyEntry? = nil,
        httpsProxy: ProxyEntry? = nil,
        socks5Proxy: ProxyEntry? = nil,
        noProxyHosts: [String] = []
    ) {
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.socks5Proxy = socks5Proxy
        self.noProxyHosts = noProxyHosts
    }

    // MARK: - Factory: System Settings

    /// Reads the current system proxy settings from
    /// `CFNetworkCopySystemProxySettings` and returns a `ProxyConfig`.
    /// Falls back to an empty config if the call fails or returns nothing.
    public static func system() -> ProxyConfig {
        guard
            let cfSettings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any]
        else {
            return ProxyConfig()
        }
        return ProxyConfig(systemSettings: cfSettings)
    }

    /// Convenience: no proxy at all.
    public static let disabled = ProxyConfig()

    // MARK: - Apply to URLSessionConfiguration

    /// Injects the proxy settings into `configuration.connectionProxyDictionary`.
    /// Existing keys are merged; this config's values take precedence.
    public func applyTo(configuration: URLSessionConfiguration) {
        var dict: [AnyHashable: Any] = configuration.connectionProxyDictionary ?? [:]

        if let http = httpProxy {
            dict[kCFNetworkProxiesHTTPEnable as String] = true
            dict[kCFNetworkProxiesHTTPProxy as String] = http.host
            dict[kCFNetworkProxiesHTTPPort as String] = http.port
        }

        if let https = httpsProxy {
            // URLSession uses the HTTPS keys for TLS traffic.
            dict[kCFNetworkProxiesHTTPSEnable as String] = true
            dict[kCFNetworkProxiesHTTPSProxy as String] = https.host
            dict[kCFNetworkProxiesHTTPSPort as String] = https.port
        }

        if let socks = socks5Proxy {
            dict[kCFNetworkProxiesSOCKSEnable as String] = true
            dict[kCFNetworkProxiesSOCKSProxy as String] = socks.host
            dict[kCFNetworkProxiesSOCKSPort as String] = socks.port
            // SOCKS version — 5 = SOCKS5
            dict["SOCKSVersion" as AnyHashable] = 5
        }

        if !noProxyHosts.isEmpty {
            dict[kCFNetworkProxiesExceptionsList as String] = noProxyHosts
        }

        configuration.connectionProxyDictionary = dict
    }

    // MARK: - Private Init from System Settings

    private init(systemSettings s: [String: Any]) {
        // HTTP
        if let enabled = s[kCFNetworkProxiesHTTPEnable as String] as? Int, enabled != 0,
           let host = s[kCFNetworkProxiesHTTPProxy as String] as? String,
           let port = s[kCFNetworkProxiesHTTPPort as String] as? Int
        {
            httpProxy = ProxyEntry(host: host, port: port)
        }

        // HTTPS
        if let enabled = s[kCFNetworkProxiesHTTPSEnable as String] as? Int, enabled != 0,
           let host = s[kCFNetworkProxiesHTTPSProxy as String] as? String,
           let port = s[kCFNetworkProxiesHTTPSPort as String] as? Int
        {
            httpsProxy = ProxyEntry(host: host, port: port)
        }

        // SOCKS
        if let enabled = s[kCFNetworkProxiesSOCKSEnable as String] as? Int, enabled != 0,
           let host = s[kCFNetworkProxiesSOCKSProxy as String] as? String,
           let port = s[kCFNetworkProxiesSOCKSPort as String] as? Int
        {
            socks5Proxy = ProxyEntry(host: host, port: port)
        }

        // Exception list
        noProxyHosts = s[kCFNetworkProxiesExceptionsList as String] as? [String] ?? []
    }
}
