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

/// The production store: one `kSecClassGenericPassword` item per key.
///
/// The **opaque key** is the `kSecAttrAccount` — that (with `kSecAttrService`) is the item's real
/// primary key, so two logical credentials never collide. The username and password both live in the
/// encrypted data payload (an earlier design put the username in `kSecAttrAccount`, which made a proxy
/// and a site that shared a username — e.g. both empty — map to the same item and silently clobber each
/// other). `…ThisDeviceOnly` keeps these secrets off any iCloud Keychain sync.
public struct KeychainCredentialStore: CredentialStoring {
    private let service: String

    public init(service: String = "com.cloakyard.cloakdrop.credentials") {
        self.service = service
    }

    private struct Payload: Codable { let username: String; let password: String }

    private func query(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    public func setCredential(_ credential: StoredCredential?, forKey key: String) {
        // Replace semantics: delete any existing item for this exact key first.
        SecItemDelete(query(forKey: key) as CFDictionary)
        guard let credential,
              let data = try? JSONEncoder().encode(Payload(username: credential.username, password: credential.password))
        else { return }
        var add = query(forKey: key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    public func credential(forKey key: String) -> StoredCredential? {
        var query = query(forKey: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return StoredCredential(username: payload.username, password: payload.password)
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
