import Foundation
import Testing
@testable import DownloadModels

@Suite("Malformed manifest input safety")
struct ManifestInputSafetyTests {
    private let base = URL(string: "https://cdn.example/manifest")!

    @Test("Malformed HLS byte ranges fail instead of trapping or downloading whole resources",
           arguments: ["", "@", "1@", "1@invalid", "9223372036854775807@2", "-1@0"])
    func rejectsMalformedHLSRanges(_ range: String) {
        let playlist = "#EXTM3U\n#EXTINF:6,\n#EXT-X-BYTERANGE:\(range)\nvideo.mp4\n#EXT-X-ENDLIST"
        #expect(throws: MediaParseError.self) { _ = try HLSParser.parse(playlist, baseURL: base) }
    }

    @Test("HLS initialization byte ranges receive the same validation")
    func rejectsMalformedHLSInitRange() {
        let playlist = "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\",BYTERANGE=\"\"\n#EXTINF:6,\nvideo.m4s\n#EXT-X-ENDLIST"
        #expect(throws: MediaParseError.self) { _ = try HLSParser.parse(playlist, baseURL: base) }
    }

    @Test("Unsafe HLS durations never enter media/UI arithmetic", arguments: ["NaN", "inf", "-1", "1e308"])
    func rejectsInvalidHLSDurations(_ duration: String) {
        let playlist = "#EXTM3U\n#EXTINF:\(duration),\nvideo.ts\n#EXT-X-ENDLIST"
        #expect(throws: MediaParseError.self) { _ = try HLSParser.parse(playlist, baseURL: base) }
    }

    @Test("HLS sequence overflow fails before incrementing an untrusted Int.max")
    func rejectsHLSSequenceOverflow() {
        let playlist = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:\(Int.max)\n#EXTINF:6,\nvideo.ts\n#EXT-X-ENDLIST"
        #expect(throws: MediaParseError.self) { _ = try HLSParser.parse(playlist, baseURL: base) }
    }

    @Test("DASH timeline number and time arithmetic cannot overflow",
           arguments: [
            "startNumber=\"9223372036854775807\"><SegmentTimeline><S d=\"1\" r=\"1\"/></SegmentTimeline>",
            "><SegmentTimeline><S t=\"9223372036854775807\" d=\"1\" r=\"1\"/></SegmentTimeline>",
            "startNumber=\"9223372036854775807\" duration=\"1\">",
            "duration=\"9223372036854775807\">"
           ])
    func rejectsDASHArithmeticOverflow(_ attributes: String) {
        let mpd = """
        <MPD mediaPresentationDuration="PT999999999999S"><Period>
          <AdaptationSet contentType="video"><Representation id="v" width="1280" height="720">
            <SegmentTemplate media="s-$Number$-$Time$.m4s" timescale="1000000000" \(attributes)</SegmentTemplate>
          </Representation></AdaptationSet>
        </Period></MPD>
        """
        #expect(throws: MediaParseError.self) { _ = try DASHParser.parse(Data(mpd.utf8), baseURL: base) }
    }

    @Test("Remote template padding cannot allocate a manifest-controlled giant string")
    func boundsTemplatePadding() {
        let expanded = DASHParser.expand("segment-$Number%0999999999d$.m4s", repID: "v", bandwidth: 1, number: 7, time: nil)
        #expect(expanded.count <= 80)
        #expect(expanded.hasSuffix("7.m4s"))
    }

    @Test("DASH durations cannot produce non-finite values through zero timescale or enormous periods")
    func boundsDASHDuration() throws {
        let mpd = """
        <MPD><Period><AdaptationSet contentType="video"><Representation id="v">
          <SegmentList duration="1" timescale="0"><SegmentURL media="video.m4s"/></SegmentList>
        </Representation></AdaptationSet></Period></MPD>
        """
        #expect(throws: MediaParseError.self) { _ = try DASHParser.parse(Data(mpd.utf8), baseURL: base) }
        #expect(DASHParser.parseISO8601Duration("PT999999999999999999999999999999S") == nil)
    }

    @Test("Untrusted HLS and DASH dimensions cannot overflow quality ranking")
    func boundsDimensions() throws {
        let hls = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=\(Int.max)x\(Int.max)\nvideo.m3u8"
        let hlsStream = try HLSParser.parse(hls, baseURL: base)
        #expect(hlsStream.bestVariant?.resolution == nil)
        let mpd = """
        <MPD><Period><AdaptationSet contentType="video">
          <Representation id="v" width="\(Int.max)" height="\(Int.max)"><BaseURL>video.mp4</BaseURL></Representation>
        </AdaptationSet></Period></MPD>
        """
        let dashStream = try DASHParser.parse(Data(mpd.utf8), baseURL: base)
        #expect(dashStream.bestVariant?.resolution == nil)
    }
}
