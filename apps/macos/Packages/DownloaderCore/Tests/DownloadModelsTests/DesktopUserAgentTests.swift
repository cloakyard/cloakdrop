import Foundation
import Testing
@testable import DownloadModels

@Suite("Desktop user agent")
struct DesktopUserAgentTests {
    @Test("Safari fallbacks follow the current macOS major")
    func currentMajor() {
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 1)
        #expect(DesktopUserAgent.safariProduct(osVersion: version) == "Version/27.0 Safari/605.1.15")
        #expect(DesktopUserAgent.safari(osVersion: version).hasSuffix("Version/27.0 Safari/605.1.15"))
    }
}
