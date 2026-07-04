import Foundation
import Testing
@testable import DownloadModels

@Suite("Subtitle converter (WebVTT/SRT → SRT)")
struct SubtitleConverterTests {
    @Test("A basic WebVTT document becomes renumbered SRT with comma millis and no header")
    func basicWebVTT() throws {
        let vtt = """
        WEBVTT

        00:00:01.000 --> 00:00:04.000
        Hello world

        00:00:05.500 --> 00:00:08.250
        Second line
        """
        let srt = try #require(SubtitleConverter.toSRT(vtt))
        #expect(srt == "1\n00:00:01,000 --> 00:00:04,000\nHello world\n\n"
                     + "2\n00:00:05,500 --> 00:00:08,250\nSecond line\n\n")
    }

    @Test("Hour-less timestamps expand to HH:MM:SS,mmm")
    func hourlessTimestamps() throws {
        let vtt = "WEBVTT\n\n01:02.500 --> 01:05.000\nText"
        let srt = try #require(SubtitleConverter.toSRT(vtt))
        #expect(srt.contains("00:01:02,500 --> 00:01:05,000"))
    }

    @Test("NOTE, STYLE, and REGION blocks and cue identifiers are dropped")
    func skipsNonCueBlocks() throws {
        let vtt = """
        WEBVTT

        NOTE this is a comment

        STYLE
        ::cue { color: yellow }

        intro-1
        00:00:00.000 --> 00:00:02.000
        Only cue
        """
        let srt = try #require(SubtitleConverter.toSRT(vtt))
        #expect(srt == "1\n00:00:00,000 --> 00:00:02,000\nOnly cue\n\n")
        #expect(!srt.contains("comment"))
        #expect(!srt.contains("intro-1"))
    }

    @Test("Cue settings after the end timestamp are stripped")
    func stripsCueSettings() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000 line:0 position:20% align:start\nPositioned"
        let srt = try #require(SubtitleConverter.toSRT(vtt))
        #expect(srt == "1\n00:00:01,000 --> 00:00:02,000\nPositioned\n\n")
    }

    @Test("Inline tags and mid-cue timestamp tags are stripped; entities decoded")
    func stripsInlineMarkup() throws {
        let vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:03.000\n<v Bob><c.loud>Hi</c> <00:00:02.000>there &amp; friends</v>"
        let srt = try #require(SubtitleConverter.toSRT(vtt))
        #expect(srt == "1\n00:00:01,000 --> 00:00:03,000\nHi there & friends\n\n")
    }

    @Test("X-TIMESTAMP-MAP shifts every cue onto the presentation timeline")
    func appliesTimestampMap() throws {
        // MPEGTS 900000 / 90000 = 10s; LOCAL 0 → +10s offset.
        let vtt = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n00:00:01.000 --> 00:00:02.000\nShifted"
        let srt = try #require(SubtitleConverter.toSRT(vtt))
        #expect(srt.contains("00:00:11,000 --> 00:00:12,000"))
    }

    @Test("Already-SRT input passes through, renumbered")
    func srtPassthrough() throws {
        let input = """
        7
        00:00:01,000 --> 00:00:02,000
        Alpha

        8
        00:00:03,000 --> 00:00:04,000
        Beta
        """
        let srt = try #require(SubtitleConverter.toSRT(input))
        #expect(srt == "1\n00:00:01,000 --> 00:00:02,000\nAlpha\n\n"
                     + "2\n00:00:03,000 --> 00:00:04,000\nBeta\n\n")
    }

    @Test("A header-only or cue-less document yields nil (no empty sidecar)")
    func emptyYieldsNil() {
        #expect(SubtitleConverter.toSRT("WEBVTT\n\n") == nil)
        #expect(SubtitleConverter.toSRT("") == nil)
        #expect(SubtitleConverter.toSRT("not a subtitle at all") == nil)
    }

    @Test("Segmented WebVTT concatenates, sorts by time, and de-dupes boundary repeats")
    func concatenatesSegments() throws {
        let seg0 = "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nA"
        let seg1 = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nB"
        // B repeats across the boundary in the next segment — the duplicate must collapse.
        let seg2 = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nB\n\n00:00:02.000 --> 00:00:03.000\nC"
        let srt = try #require(SubtitleConverter.segmentsToSRT([seg0, seg1, seg2]))
        #expect(srt == "1\n00:00:00,000 --> 00:00:01,000\nA\n\n"
                     + "2\n00:00:01,000 --> 00:00:02,000\nB\n\n"
                     + "3\n00:00:02,000 --> 00:00:03,000\nC\n\n")
    }

    @Test("Timestamp parsing accepts H:MM:SS, MM:SS, and comma millis")
    func parsesTimestamps() {
        #expect(SubtitleConverter.parseTimestamp("01:02:03.500") == 3723.5)
        #expect(SubtitleConverter.parseTimestamp("02:03.250") == 123.25)
        #expect(SubtitleConverter.parseTimestamp("00:00:01,000") == 1.0)
        #expect(SubtitleConverter.parseTimestamp("garbage") == nil)
    }

    @Test("SRT timestamp formatting rounds to milliseconds and clamps negatives to zero")
    func formatsSRTTimestamps() {
        #expect(SubtitleConverter.srtTimestamp(3723.5) == "01:02:03,500")
        #expect(SubtitleConverter.srtTimestamp(0) == "00:00:00,000")
        #expect(SubtitleConverter.srtTimestamp(-5) == "00:00:00,000")
    }
}
