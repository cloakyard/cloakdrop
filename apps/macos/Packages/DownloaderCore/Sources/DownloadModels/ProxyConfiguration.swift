import Foundation

/// How the engine routes its connections. Persisted as part of `EngineSettings`.
///
/// `system` defers to macOS's configured proxy (the default `URLSession` behavior); `direct`
/// bypasses any system proxy; `manual` routes through an explicit host/port (with optional
/// credentials). Per the privacy model, a proxy is the *only* network egress permitted beyond
/// the user's chosen download URLs.
public struct ProxyConfiguration: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Codable, CaseIterable, Identifiable {
        case system, direct, manual
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .system: return "Use system proxy"
            case .direct: return "Direct connection (no proxy)"
            case .manual: return "Manual configuration"
            }
        }
    }

    public enum ProxyType: String, Sendable, Codable, CaseIterable, Identifiable {
        case http, https, socks5
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .http: return "HTTP"
            case .https: return "HTTPS"
            case .socks5: return "SOCKS5"
            }
        }
    }

    public var mode: Mode
    public var type: ProxyType
    public var host: String
    public var port: Int
    public var username: String
    /// Stored alongside other local state. (A future hardening could move this to the Keychain.)
    public var password: String

    public init(
        mode: Mode = .system,
        type: ProxyType = .http,
        host: String = "",
        port: Int = 8080,
        username: String = "",
        password: String = ""
    ) {
        self.mode = mode
        self.type = type
        self.host = host
        self.port = port
        self.username = username
        self.password = password
    }

    public static let system = ProxyConfiguration(mode: .system)

    /// A manual proxy is only usable once it has a host and a valid port.
    public var isUsableManualProxy: Bool {
        mode == .manual && !host.trimmingCharacters(in: .whitespaces).isEmpty && (1...65_535).contains(port)
    }

    public var requiresCredentials: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
