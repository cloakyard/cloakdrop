import Foundation
import CFNetwork
import Network
import Testing
import DownloadModels
@testable import DownloadEngine

@Suite("Proxy routing")
struct ProxyRoutingTests {
    @Test("System routing clears explicit overrides")
    func systemRouting() {
        let base = URLSessionConfiguration.ephemeral
        base.proxyConfigurations = [testNetworkProxy()]
        base.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0]

        let routed = ProxyRouting.applying(.system, to: base)

        #expect(routed !== base)
        #expect(routed.proxyConfigurations.isEmpty)
        #expect(routed.connectionProxyDictionary == nil)
        #expect(base.proxyConfigurations.count == 1)
    }

    @Test("Direct routing disables system, PAC, and explicit proxies")
    func directRouting() {
        let routed = ProxyRouting.applying(DownloadModels.ProxyConfiguration(mode: .direct), to: .ephemeral)
        let dictionary = routed.connectionProxyDictionary

        #expect(routed.proxyConfigurations.isEmpty)
        #expect(dictionary?[kCFNetworkProxiesHTTPEnable as String] as? Int == 0)
        #expect(dictionary?[kCFNetworkProxiesHTTPSEnable as String] as? Int == 0)
        #expect(dictionary?[kCFNetworkProxiesSOCKSEnable as String] as? Int == 0)
        #expect(dictionary?[kCFNetworkProxiesProxyAutoConfigEnable as String] as? Int == 0)
        #expect(dictionary?[kCFNetworkProxiesProxyAutoDiscoveryEnable as String] as? Int == 0)
    }

    @Test(
        "Every manual proxy type creates one global, no-failover modern route",
        arguments: [
            (DownloadModels.ProxyConfiguration.ProxyType.http, "http_connect"),
            (.https, "http_connect"),
            (.socks5, "socksv5")
        ]
    )
    func manualRouting(type: DownloadModels.ProxyConfiguration.ProxyType, debugPrefix: String) throws {
        let proxy = DownloadModels.ProxyConfiguration(
            mode: .manual,
            type: type,
            host: "  proxy.example  ",
            port: 8_080,
            username: "alice",
            password: "secret"
        )

        let configurations = ProxyRouting.networkConfigurations(for: proxy)
        let configuration = try #require(configurations.first)
        let routed = ProxyRouting.applying(proxy, to: .ephemeral)

        #expect(configurations.count == 1)
        #expect(configuration.debugDescription.hasPrefix(debugPrefix))
        #expect(configuration.debugDescription.contains("proxy.example:8080"))
        #expect(configuration.matchDomains.isEmpty)
        #expect(configuration.excludedDomains.isEmpty)
        #expect(!configuration.allowFailover)
        #expect(routed.proxyConfigurations.count == 1)
        #expect(routed.connectionProxyDictionary == nil)
    }

    @Test("Incomplete manual routing fails closed")
    func incompleteManualRouting() {
        for proxy in [
            DownloadModels.ProxyConfiguration(mode: .manual, host: "", port: 8_080),
            DownloadModels.ProxyConfiguration(mode: .manual, host: " \n ", port: 8_080),
            DownloadModels.ProxyConfiguration(mode: .manual, host: "proxy.example", port: 0),
            DownloadModels.ProxyConfiguration(mode: .manual, host: "proxy.example", port: 65_536)
        ] {
            let routed = ProxyRouting.applying(proxy, to: .ephemeral)
            #expect(routed.proxyConfigurations.count == 1)
            #expect(routed.proxyConfigurations[0].debugDescription.contains("127.0.0.1:1"))
            #expect(!routed.proxyConfigurations[0].allowFailover)
            #expect(routed.connectionProxyDictionary == nil)
        }
    }

    @Test(
        "Incomplete manual routing cannot reach HTTP or HTTPS origins",
        arguments: ["http://example.com", "https://example.com"]
    )
    func incompleteManualCannotLeakDirectly(urlString: String) async throws {
        let base = URLSessionConfiguration.ephemeral
        base.timeoutIntervalForRequest = 3
        let routed = ProxyRouting.applying(
            DownloadModels.ProxyConfiguration(mode: .manual, host: "", port: 8_080),
            to: base
        )
        let session = URLSession(configuration: routed)
        defer { session.invalidateAndCancel() }

        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: try #require(URL(string: urlString)))
        }
    }

    private func testNetworkProxy() -> Network.ProxyConfiguration {
        Network.ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: "existing.example", port: 3_128)
        )
    }
}
