import Foundation
import Testing
@testable import DownloadModels

@Suite("Proxy configuration compatibility")
struct ProxyConfigurationTests {
    @Test(
        "Legacy proxy type values still decode",
        arguments: ProxyConfiguration.ProxyType.allCases
    )
    func legacyTypeDecoding(type: ProxyConfiguration.ProxyType) throws {
        let json = #"{"mode":"manual","type":"\#(type.rawValue)","host":"proxy.example","port":8080,"username":"u","password":"p"}"#
        let decoded = try JSONDecoder().decode(ProxyConfiguration.self, from: Data(json.utf8))

        #expect(decoded.type == type)
        #expect(decoded.mode == .manual)
        #expect(decoded.host == "proxy.example")
        #expect(decoded.port == 8_080)
        #expect(decoded.username == "u")
        #expect(decoded.password == "p")
    }
}
