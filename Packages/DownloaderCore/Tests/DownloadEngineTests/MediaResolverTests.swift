import Foundation
import Testing
@testable import DownloadModels
@testable import DownloadEngine

@Suite("Media resolver")
struct MediaResolverTests {
    private func client(_ pairs: [(String, String)]) -> MockHTTPClient {
        let mock = MockHTTPClient()
        for (urlString, body) in pairs {
            mock.setResource(.init(data: Data(body.utf8)), for: URL(string: urlString)!)
        }
        return mock
    }

    @Test("Resolves an HLS multivariant playlist to a plan for the best variant (second fetch)")
    func resolvesHLSMultivariant() async throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        seg0.ts
        #EXTINF:6.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let base = "https://cdn.example.com/v/master.m3u8"
        let mock = client([(base, master), ("https://cdn.example.com/v/1080p.m3u8", media)])
        let plan = try await MediaResolver(httpClient: mock).resolvePlan(url: URL(string: base)!)

        #expect(plan.format == .hls)
        #expect(plan.bandwidth == 2_400_000)
        #expect(plan.resolution == MediaResolution(width: 1920, height: 1080))
        #expect(plan.segments.count == 2)
        #expect(plan.segments[0].url.absoluteString == "https://cdn.example.com/v/seg0.ts")
        #expect(mock.streamCount == 2) // master + the chosen variant's media playlist
    }

    @Test("A specific variantID selects that rendition")
    func resolvesChosenVariant() async throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        360p.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1920x1080
        1080p.m3u8
        """
        let media360 = "#EXTM3U\n#EXTINF:6,\nlow.ts\n#EXT-X-ENDLIST"
        let base = "https://cdn.example.com/v/master.m3u8"
        let mock = client([(base, master), ("https://cdn.example.com/v/360p.m3u8", media360)])
        // Variant ids are assigned in order, so "0" is the 360p rendition.
        let plan = try await MediaResolver(httpClient: mock).resolvePlan(url: URL(string: base)!, variantID: "0")
        #expect(plan.bandwidth == 800_000)
        #expect(plan.segments.first?.url.absoluteString == "https://cdn.example.com/v/low.ts")
    }

    @Test("Resolves a lone HLS media playlist without a second fetch")
    func resolvesLoneMediaPlaylist() async throws {
        let media = "#EXTM3U\n#EXTINF:4,\na.ts\n#EXTINF:4,\nb.ts\n#EXT-X-ENDLIST"
        let base = "https://x/media.m3u8"
        let mock = client([(base, media)])
        let plan = try await MediaResolver(httpClient: mock).resolvePlan(url: URL(string: base)!)
        #expect(plan.segments.count == 2)
        #expect(mock.streamCount == 1)
    }

    @Test("A manifest larger than the size limit is rejected, not buffered unbounded into memory")
    func rejectsOversizedManifest() async throws {
        let base = "https://cdn.example.com/v/huge.m3u8"
        let body = "#EXTM3U\n" + String(repeating: "#EXTINF:1,\nseg.ts\n", count: 500)  // ~9 KB
        let mock = client([(base, body)])
        let resolver = MediaResolver(httpClient: mock, maxManifestBytes: 1024)   // 1 KB ceiling
        await #expect(throws: MediaParseError.self) {
            _ = try await resolver.fetchManifest(url: URL(string: base)!)
        }
    }

    @Test("Resolves a DASH manifest straight from the .mpd (no second fetch)")
    func resolvesDASH() async throws {
        let mpd = """
        <MPD mediaPresentationDuration="PT12S">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="1000000" width="1280" height="720">
                <SegmentTemplate media="seg-$Number$.m4s" initialization="init.mp4" startNumber="1" duration="6000" timescale="1000"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let base = "https://x/manifest.mpd"
        let mock = client([(base, mpd)])
        let plan = try await MediaResolver(httpClient: mock).resolvePlan(url: URL(string: base)!)
        #expect(plan.format == .dash)
        #expect(plan.segments.count == 2)  // 12s / 6s
        #expect(plan.initSegment != nil)
        #expect(mock.streamCount == 1)
    }
}
