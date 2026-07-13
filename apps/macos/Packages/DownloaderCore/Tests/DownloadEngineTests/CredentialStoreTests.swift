import Foundation
import Testing
@testable import DownloadEngine

@Suite("Credential store")
struct CredentialStoreTests {
    @Test("Stores, retrieves, and removes a credential by key")
    func roundTrip() {
        let store = InMemoryCredentialStore()
        let key = InMemoryCredentialStore.siteKey(host: "ftp.example.com")

        #expect(store.credential(forKey: key) == nil)

        store.setCredential(StoredCredential(username: "alice", password: "s3cret"), forKey: key)
        let loaded = store.credential(forKey: key)
        #expect(loaded?.username == "alice")
        #expect(loaded?.password == "s3cret")

        store.setCredential(nil, forKey: key)
        #expect(store.credential(forKey: key) == nil)
    }

    @Test("Keys are namespaced so a proxy and a same-named site don't collide")
    func keyNamespacing() {
        let store = InMemoryCredentialStore()
        store.setCredential(StoredCredential(username: "proxyuser", password: "p"), forKey: InMemoryCredentialStore.proxyKey(host: "h", port: 8080))
        store.setCredential(StoredCredential(username: "siteuser", password: "s"), forKey: InMemoryCredentialStore.siteKey(host: "h"))

        #expect(store.credential(forKey: InMemoryCredentialStore.proxyKey(host: "h", port: 8080))?.username == "proxyuser")
        #expect(store.credential(forKey: InMemoryCredentialStore.siteKey(host: "h"))?.username == "siteuser")
    }
}
