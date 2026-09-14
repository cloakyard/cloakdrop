import Foundation
import Testing
@testable import DownloadEngine

@Suite("Credential store")
struct CredentialStoreTests {
    @Test("Stores, retrieves, and removes a credential by key")
    func roundTrip() throws {
        let store = InMemoryCredentialStore()
        let key = try #require(CredentialScope(url: URL(string: "ftp://ftp.example.com/file")!)).key

        #expect(store.credential(forKey: key) == nil)

        store.setCredential(StoredCredential(username: "alice", password: "s3cret"), forKey: key)
        let loaded = store.credential(forKey: key)
        #expect(loaded?.username == "alice")
        #expect(loaded?.password == "s3cret")

        store.setCredential(nil, forKey: key)
        #expect(store.credential(forKey: key) == nil)
    }

    @Test("Keys are namespaced so a proxy and a same-named site don't collide")
    func keyNamespacing() throws {
        let key = try #require(CredentialScope(url: URL(string: "http://h:8080/")!)).key
        let store = InMemoryCredentialStore()
        store.setCredential(StoredCredential(username: "proxyuser", password: "p"), forKey: InMemoryCredentialStore.proxyKey(host: "h", port: 8080))
        store.setCredential(StoredCredential(username: "siteuser", password: "s"), forKey: key)

        #expect(store.credential(forKey: InMemoryCredentialStore.proxyKey(host: "h", port: 8080))?.username == "proxyuser")
        #expect(store.credential(forKey: key)?.username == "siteuser")
    }

    @Test("Saved credentials are isolated by scheme and effective port")
    func originScope() throws {
        let https = try #require(CredentialScope(url: URL(string: "https://EXAMPLE.com/file")!))
        #expect(https == CredentialScope(url: URL(string: "https://example.com:443/other")!))
        for address in ["http://example.com", "https://example.com:8443", "ftp://example.com", "ftps://example.com"] {
            #expect(https != CredentialScope(url: URL(string: address)!))
        }
        let challenge = URLProtectionSpace(host: "example.com", port: 443, protocol: "https", realm: "members",
                                           authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(https == CredentialScope(protectionSpace: challenge))
        let proxy = URLProtectionSpace(proxyHost: "example.com", port: 443, type: NSURLProtectionSpaceHTTPSProxy,
                                       realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(https != CredentialScope(protectionSpace: proxy))
        #expect(CredentialScope(url: URL(string: "file:///tmp/a")!) == nil)
        #expect(CredentialScope(url: URL(string: "https://example.com:65536")!) == nil)
    }

}
