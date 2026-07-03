import Foundation
import Security

/// A username/password pair the engine can use for HTTP/FTP auth or a proxy.
public struct StoredCredential: Sendable, Hashable {
    public let username: String
    public let password: String
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Where site/proxy credentials live. A protocol so the plaintext-free production path (the macOS
/// Keychain) can be swapped for an in-memory fake in tests — Keychain access needs a signed,
/// entitled process, which a SwiftPM test runner isn't.
///
/// Keys are opaque identifiers the caller chooses (e.g. a host, or `proxy:host:port`); the store maps
/// one key → one credential.
public protocol CredentialStoring: Sendable {
    /// Store (or, with `nil`, remove) the credential for `key`.
    func setCredential(_ credential: StoredCredential?, forKey key: String)
    /// Look up the credential for `key`, or `nil` if none is stored.
    func credential(forKey key: String) -> StoredCredential?
}

/// The production store: one `kSecClassGenericPassword` item per key. The username rides in
/// `kSecAttrAccount` and the password is the secret payload, so nothing sensitive is ever written to
/// the settings/download JSON on disk.
public struct KeychainCredentialStore: CredentialStoring {
    private let service: String

    public init(service: String = "com.cloakyard.cloakdrop.credentials") {
        self.service = service
    }

    private func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrGeneric as String: Data(key.utf8)   // our key, kept out of account (which holds the username)
        ]
    }

    public func setCredential(_ credential: StoredCredential?, forKey key: String) {
        // Replace semantics: delete any existing item for this key first.
        SecItemDelete(baseQuery(forKey: key) as CFDictionary)
        guard let credential else { return }
        var add = baseQuery(forKey: key)
        add[kSecAttrAccount as String] = credential.username
        add[kSecValueData as String] = Data(credential.password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public func credential(forKey key: String) -> StoredCredential? {
        var query = baseQuery(forKey: key)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let data = dict[kSecValueData as String] as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        let username = dict[kSecAttrAccount as String] as? String ?? ""
        return StoredCredential(username: username, password: password)
    }
}

/// An in-memory `CredentialStoring` for tests and previews. Thread-safe via a lock so it satisfies
/// `Sendable`.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: StoredCredential] = [:]

    public init() {}

    public func setCredential(_ credential: StoredCredential?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = credential
    }

    public func credential(forKey key: String) -> StoredCredential? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }
}

public extension CredentialStoring {
    /// The conventional Keychain key for a manual proxy's credentials.
    static func proxyKey(host: String, port: Int) -> String { "proxy:\(host):\(port)" }
    /// The conventional Keychain key for a site host's credentials.
    static func siteKey(host: String) -> String { "site:\(host)" }
}
