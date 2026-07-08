import Foundation
import Testing
@testable import DownloadModels

@Suite("Speed test models")
struct SpeedTestModelTests {

    @Test func providerDefaultsToCloudflare() {
        #expect(EngineSettings.default.resolvedSpeedTestProvider == .cloudflare)

        var settings = EngineSettings.default
        settings.speedTestProvider = .ookla
        #expect(settings.resolvedSpeedTestProvider == .ookla)
    }

    /// A settings blob written before the speed test existed must still decode (launch-on-upgrade
    /// safety) and resolve to the Cloudflare default.
    @Test func legacySettingsBlobDecodesWithoutProvider() throws {
        let legacy = Data(#"{"defaultSegmentCount": 4}"#.utf8)
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: legacy)
        #expect(decoded.defaultSegmentCount == 4)
        #expect(decoded.speedTestProvider == nil)
        #expect(decoded.resolvedSpeedTestProvider == .cloudflare)
    }

    /// An unknown provider raw value (written by a newer build) must degrade to the default,
    /// not fail the whole settings blob — losing every other setting on downgrade.
    @Test func unknownProviderRawValueDegradesGracefully() throws {
        let blob = Data(#"{"defaultSegmentCount": 6, "speedTestProvider": "somefutureprovider"}"#.utf8)
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: blob)
        #expect(decoded.speedTestProvider == nil)
        #expect(decoded.resolvedSpeedTestProvider == .cloudflare)
        #expect(decoded.defaultSegmentCount == 6)
    }

    @Test func settingsRoundTripKeepsProvider() throws {
        var settings = EngineSettings.default
        settings.speedTestProvider = .ookla
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.speedTestProvider == .ookla)
    }

    @Test func resultRoundTrips() throws {
        let result = SpeedTestResult(
            provider: .cloudflare,
            serverName: "Cloudflare",
            downloadBytesPerSecond: 42_000_000,
            uploadBytesPerSecond: 8_000_000,
            idleLatencyMilliseconds: 12.5,
            loadedLatencyMilliseconds: 87.25,
            jitterMilliseconds: 1.75,
            date: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try JSONDecoder().decode(SpeedTestResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
    }
}
