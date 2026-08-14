import Foundation
import CFNetwork
import Network
import DownloadModels

/// Builds the one proxy representation shared by downloads, speed tests, and WebKit.
public enum ProxyRouting {
    /// A manual proxy applies to every destination; an empty array means system routing.
    /// `direct` is handled separately for URLSession because Network has no bypass sentinel.
    public static func networkConfigurations(for proxy: DownloadModels.ProxyConfiguration) -> [Network.ProxyConfiguration] {
        guard proxy.mode == .manual else { return [] }
        let host = proxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard proxy.isUsableManualProxy,
              let rawPort = UInt16(exactly: proxy.port),
              let port = NWEndpoint.Port(rawValue: rawPort) else { return [blockingConfiguration()] }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var configuration: Network.ProxyConfiguration
        switch proxy.type {
        case .http:
            configuration = Network.ProxyConfiguration(httpCONNECTProxy: endpoint)
        case .https:
            configuration = Network.ProxyConfiguration(
                httpCONNECTProxy: endpoint,
                tlsOptions: NWProtocolTLS.Options()
            )
        case .socks5:
            configuration = Network.ProxyConfiguration(socksv5Proxy: endpoint)
        }
        configuration.allowFailover = false
        if proxy.requiresCredentials {
            configuration.applyCredential(username: proxy.username, password: proxy.password)
        }
        return [configuration]
    }

    /// Returns a copy so sessions already using `base` cannot observe a mid-flight mutation.
    static func applying(
        _ proxy: DownloadModels.ProxyConfiguration,
        to base: URLSessionConfiguration
    ) -> URLSessionConfiguration {
        guard let configuration = base.copy() as? URLSessionConfiguration else { return base }
        configuration.proxyConfigurations = networkConfigurations(for: proxy)

        // Apple documents an empty modern array as "use system settings". The legacy override is
        // therefore still required for direct mode, but manual proxies use only the modern API.
        configuration.connectionProxyDictionary = proxy.mode == .direct ? directProxyOverride : nil
        return configuration
    }

    private static var directProxyOverride: [String: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesHTTPSEnable as String: 0,
            kCFNetworkProxiesSOCKSEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
            kCFNetworkProxiesProxyAutoDiscoveryEnable as String: 0
        ]
    }

    /// Selecting manual routing must never fall through to the system path while a setting is
    /// incomplete. Loopback's privileged port 1 is a valid endpoint that an unprivileged process
    /// cannot occupy; disabled failover prevents a direct retry when the connection is refused.
    private static func blockingConfiguration() -> Network.ProxyConfiguration {
        var configuration = Network.ProxyConfiguration(
            httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: 1)
        )
        configuration.allowFailover = false
        return configuration
    }
}
