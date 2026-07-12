import Foundation
import Testing
@testable import DownloadModels

@Suite("DASH parser")
struct DASHParserTests {
    private let base = URL(string: "https://cdn.example.com/manifest.mpd")!

    private func parse(_ xml: String, base: URL? = nil) throws -> MediaStream {
        try DASHParser.parse(Data(xml.utf8), baseURL: base ?? self.base)
    }

    // MARK: SegmentTemplate + SegmentTimeline (with the real MPD namespace)

    @Test("Parses SegmentTemplate + SegmentTimeline, video variant and audio track, chained BaseURL")
    func parsesTemplateTimeline() throws {
        let mpd = """
        <?xml version="1.0" encoding="UTF-8"?>
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" mediaPresentationDuration="PT30S" type="static">
          <Period>
            <BaseURL>dash/</BaseURL>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v0" bandwidth="1200000" width="1280" height="720" codecs="avc1.4d401f" frameRate="30000/1001">
                <SegmentTemplate media="v0/seg-$Number$.m4s" initialization="v0/init.mp4" startNumber="1" timescale="1000">
                  <SegmentTimeline><S t="0" d="10000" r="2"/></SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
            <AdaptationSet contentType="audio" mimeType="audio/mp4" lang="en">
              <Representation id="a0" bandwidth="128000" codecs="mp4a.40.2">
                <SegmentTemplate media="a0/seg-$Number$.m4s" initialization="a0/init.mp4" startNumber="1" timescale="1000">
                  <SegmentTimeline><S t="0" d="10000" r="2"/></SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try parse(mpd)
        #expect(stream.format == .dash)
        #expect(stream.variants.count == 1)
        #expect(stream.audioTracks.count == 1)

        let video = try #require(stream.variants.first)
        #expect(video.bandwidth == 1_200_000)
        #expect(video.resolution == MediaResolution(width: 1280, height: 720))
        #expect(video.codecs == ["avc1.4d401f"])
        #expect(abs((video.frameRate ?? 0) - 30000.0 / 1001.0) < 0.001)
        #expect(video.segments.count == 3) // r=2 → 3 segments
        #expect(video.segments.map(\.id) == [0, 1, 2])
        // Period BaseURL "dash/" is resolved against the .mpd URL, then the media template appended.
        #expect(video.segments[0].url.absoluteString == "https://cdn.example.com/dash/v0/seg-1.m4s")
        #expect(video.segments[2].url.absoluteString == "https://cdn.example.com/dash/v0/seg-3.m4s")
        #expect(video.segments[0].duration == 10.0)
        #expect(video.initSegment?.url.absoluteString == "https://cdn.example.com/dash/v0/init.mp4")

        let audio = try #require(stream.audioTracks.first)
        #expect(audio.language == "en")
        #expect(audio.segments.count == 3)
        #expect(audio.segments[0].url.absoluteString == "https://cdn.example.com/dash/a0/seg-1.m4s")
    }

    @Test("A negative SegmentTimeline repeat fills up to the next run's explicit start time")
    func negativeRepeatFillsToNextRun() throws {
        let mpd = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="900000" width="640" height="360">
                <SegmentTemplate media="seg-$Time$.m4s" startNumber="1" timescale="90000">
                  <SegmentTimeline><S t="0" d="90000" r="-1"/><S t="9000000" d="90000"/></SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try parse(mpd)
        let video = try #require(stream.variants.first)
        // (9000000 − 0) / 90000 → 100 segments fill the gap, then the final explicit run.
        #expect(video.segments.count == 101)
        #expect(video.segments[0].url.absoluteString == "https://cdn.example.com/seg-0.m4s")
        #expect(video.segments[1].url.absoluteString == "https://cdn.example.com/seg-90000.m4s")
        #expect(video.segments[99].url.absoluteString == "https://cdn.example.com/seg-8910000.m4s")
        #expect(video.segments[100].url.absoluteString == "https://cdn.example.com/seg-9000000.m4s")
        #expect(video.segments.allSatisfy { $0.duration == 1.0 })
    }

    @Test("A trailing negative repeat fills to the presentation end, or keeps one segment when unknown")
    func trailingNegativeRepeatFillsToPresentationEnd() throws {
        func mpd(_ attributes: String) -> String {
            """
            <MPD\(attributes)>
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  <Representation id="v" bandwidth="900000" width="640" height="360">
                    <SegmentTemplate media="seg-$Number$.m4s" startNumber="1" timescale="90000">
                      <SegmentTimeline><S t="0" d="90000" r="-1"/></SegmentTimeline>
                    </SegmentTemplate>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """
        }
        // PT100S at timescale 90000 → the run fills to 100 one-second segments.
        let bounded = try parse(mpd(" mediaPresentationDuration=\"PT100S\""))
        #expect(bounded.variants.first?.segments.count == 100)
        // No next run and no period end in scope → the run keeps its single occurrence.
        let unbounded = try parse(mpd(""))
        #expect(unbounded.variants.first?.segments.count == 1)
    }

    // MARK: SegmentTemplate + fixed duration

    @Test("Derives segment count from the period duration for a fixed-duration template")
    func parsesTemplateDuration() throws {
        let mpd = """
        <MPD mediaPresentationDuration="PT25S">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="800000" width="640" height="360">
                <SegmentTemplate media="$RepresentationID$-$Number%03d$.m4s" initialization="$RepresentationID$-init.mp4" startNumber="1" duration="10000" timescale="1000"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try parse(mpd)
        let video = try #require(stream.variants.first)
        // 25s / 10s per segment → ceil = 3.
        #expect(video.segments.count == 3)
        #expect(video.segments[0].url.absoluteString == "https://cdn.example.com/v-001.m4s")
        #expect(video.segments[2].url.absoluteString == "https://cdn.example.com/v-003.m4s")
        #expect(video.initSegment?.url.absoluteString == "https://cdn.example.com/v-init.mp4")
    }

    // MARK: SegmentList

    @Test("Parses an explicit SegmentList with a representation-level BaseURL")
    func parsesSegmentList() throws {
        let mpd = """
        <MPD>
          <Period duration="PT20S">
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="500000" width="426" height="240">
                <BaseURL>video/</BaseURL>
                <SegmentList duration="10000" timescale="1000">
                  <Initialization sourceURL="init.mp4"/>
                  <SegmentURL media="seg1.m4s"/>
                  <SegmentURL media="seg2.m4s"/>
                </SegmentList>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try parse(mpd)
        let video = try #require(stream.variants.first)
        #expect(video.segments.count == 2)
        #expect(video.initSegment?.url.absoluteString == "https://cdn.example.com/video/init.mp4")
        #expect(video.segments[0].url.absoluteString == "https://cdn.example.com/video/seg1.m4s")
        #expect(video.segments[1].duration == 10.0)
    }

    // MARK: Untrusted-input bounds

    @Test("An enormous SegmentTimeline repeat count is capped, not expanded unbounded")
    func capsRunawaySegmentTimeline() throws {
        let mpd = """
        <MPD xmlns="urn:mpeg:dash:schema:mpd:2011">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="900000" width="640" height="360">
                <SegmentTemplate media="seg-$Number$.m4s" startNumber="1" timescale="1000">
                  <SegmentTimeline><S t="0" d="1" r="100000000"/></SegmentTimeline>
                </SegmentTemplate>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        let stream = try parse(mpd)
        #expect(stream.variants.first?.segments.count == DASHParser.maxSegmentsPerRepresentation)
    }

    @Test("A degenerate near-zero segment duration is guarded — no crash, no unbounded count")
    func guardsDegenerateDurationTemplate() {
        // timescale=0 → infinite per-segment seconds → zero derived count → representation dropped,
        // rather than trapping in Int(_:) on a huge/non-finite count.
        let mpd = """
        <MPD mediaPresentationDuration="PT100S">
          <Period>
            <AdaptationSet contentType="video" mimeType="video/mp4">
              <Representation id="v" bandwidth="800000" width="640" height="360">
                <SegmentTemplate media="s-$Number$.m4s" startNumber="1" duration="6000" timescale="0"/>
              </Representation>
            </AdaptationSet>
          </Period>
        </MPD>
        """
        #expect(throws: MediaParseError.noContent) { _ = try parse(mpd) }
    }

    // MARK: Errors & scalars

    @Test("A non-MPD root is rejected")
    func rejectsNonMPD() {
        #expect(throws: MediaParseError.notAPlaylist) {
            _ = try parse("<html><body>nope</body></html>")
        }
    }

    @Test("ISO 8601 durations parse to seconds")
    func parsesDurations() {
        #expect(DASHParser.parseISO8601Duration("PT30S") == 30)
        #expect(DASHParser.parseISO8601Duration("PT1M") == 60)
        #expect(DASHParser.parseISO8601Duration("PT1H2M3.5S") == 3723.5)
        #expect(DASHParser.parseISO8601Duration("P1DT2H") == 93_600)
        #expect(DASHParser.parseISO8601Duration("garbage") == nil)
        #expect(DASHParser.parseISO8601Duration(nil) == nil)
    }

    @Test("Template variables expand, including %0Nd padding and $$")
    func expandsTemplate() {
        #expect(DASHParser.expand("$RepresentationID$/seg-$Number%05d$.m4s", repID: "v0", bandwidth: 0, number: 12, time: nil)
            == "v0/seg-00012.m4s")
        #expect(DASHParser.expand("$Bandwidth$/x", repID: "", bandwidth: 128_000, number: nil, time: nil) == "128000/x")
        #expect(DASHParser.expand("t$Time$", repID: "", bandwidth: 0, number: nil, time: 96_256) == "t96256")
        #expect(DASHParser.expand("a$$b", repID: "", bandwidth: 0, number: nil, time: nil) == "a$b")
    }

    @Test("64-bit $Time$ values survive %0Nd padding without 32-bit truncation")
    func expandsWideTimeValues() {
        // String(format: "%010d", 3_240_000_000) reads only 32 bits of the vararg → "-1054967296".
        #expect(DASHParser.expand("seg-$Time%010d$.m4s", repID: "", bandwidth: 0, number: nil, time: 3_240_000_000)
            == "seg-3240000000.m4s")
        #expect(DASHParser.expand("$Time%012d$", repID: "", bandwidth: 0, number: nil, time: 3_240_000_000)
            == "003240000000")
    }
}
