import Foundation
import Testing
import DownloadModels
import DownloadPersistence
@testable import DownloadEngine

@Suite("Proxy password via Keychain")
struct ProxyCredentialTests {
    @Test("Manual-proxy password lives in the credential store, is blanked on disk, and rehydrates")
    func proxyPasswordRoundTrip() async throws {
        let store = try GRDBDownloadStore.inMemory()
        let creds = InMemoryCredentialStore()
        let manager = DownloadManager(store: store, httpClient: MockHTTPClient(),
                                      networkMonitor: AlwaysReachableMonitor(), credentialStore: creds)
        try await manager.start()

        var settings = await manager.currentSettings()
        settings.proxy = ProxyConfiguration(mode: .manual, type: .http,
                                            host: "proxy.example.com", port: 3128,
                                            username: "u", password: "s3cret")
        await manager.updateSettings(settings)

        // The password is in the credential store, and the persisted settings carry a blank.
        let key = KeychainCredentialStore.proxyKey(host: "proxy.example.com", port: 3128)
        #expect(creds.credential(forKey: key)?.password == "s3cret")
        let persisted = try await store.loadSettings()
        #expect(persisted.proxy?.password == "")
        #expect(persisted.proxy?.username == "u")   // non-secret fields still persist

        // A fresh manager on the same store + credential store rehydrates the password in memory.
        let manager2 = DownloadManager(store: store, httpClient: MockHTTPClient(),
                                       networkMonitor: AlwaysReachableMonitor(), credentialStore: creds)
        try await manager2.start()
        let hydrated = await manager2.currentSettings()
        #expect(hydrated.proxy?.password == "s3cret")
    }

    @Test("Switching proxy mode away from manual never leaves the plaintext password on disk")
    func modeSwitchDoesNotLeak() async throws {
        let store = try GRDBDownloadStore.inMemory()
        let creds = InMemoryCredentialStore()
        let manager = DownloadManager(store: store, httpClient: MockHTTPClient(),
                                      networkMonitor: AlwaysReachableMonitor(), credentialStore: creds)
        try await manager.start()

        // Save a manual proxy with a password, then switch to system WITHOUT clearing the field (the
        // SecureField retains the old plaintext) — the regression scenario.
        var settings = await manager.currentSettings()
        settings.proxy = ProxyConfiguration(mode: .manual, host: "p.example.com", port: 3128, password: "leaky")
        await manager.updateSettings(settings)
        settings.proxy?.mode = .system   // password field still holds "leaky"
        await manager.updateSettings(settings)

        let persisted = try await store.loadSettings()
        #expect(persisted.proxy?.password == "")   // must be blanked regardless of mode
    }
}
