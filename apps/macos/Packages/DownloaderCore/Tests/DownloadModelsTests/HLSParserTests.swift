import Foundation
import Testing
@testable import DownloadModels

@Suite("HLS parser")
struct HLSParserTests {
    private let base = URL(string: "https://cdn.example.com/video/master.m3u8")!

    // MARK: Master playlist

    private let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/en.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",FRAME-RATE=29.97,AUDIO="aud",SUBTITLES="sub"
    720p.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
    1080p.m3u8
    """

    @Test("Parses master variants with resolution, codecs, and rendition groups")
    func parsesMaster() throws {
        let stream = try HLSParser.parse(master, baseURL: base)
        #expect(stream.format == .hls)
        #expect(stream.variants.count == 2)

        let low = stream.variants[0]
        #expect(low.bandwidth == 1_280_000)
        #expect(low.resolution == MediaResolution(width: 1280, height: 720))
        #expect(low.codecs == ["avc1.4d401f", "mp4a.40.2"]) // comma inside the quoted CODECS survived
        #expect(low.frameRate == 29.97)
        #expect(low.playlistURL?.absoluteString == "https://cdn.example.com/video/720p.m3u8")
        #expect(low.audioGroupID == "aud")
        #expect(low.subtitleGroupID == "sub")

        // A master's variants aren't resolved until each media playlist is fetched.
        #expect(low.segments.isEmpty)
        #expect(stream.needsVariantResolution)
        #expect(stream.bestVariant?.bandwidth == 2_560_000)
        #expect(stream.bestVariant?.resolution?.pixelCount == 1920 * 1080)
    }

    @Test("Parses master audio and subtitle renditions")
    func parsesRenditions() throws {
        let stream = try HLSParser.parse(master, baseURL: base)
        #expect(stream.audioTracks.count == 1)
        #expect(stream.subtitleTracks.count == 1)

        let audio = try #require(stream.audioTracks.first)
        #expect(audio.kind == .audio)
        #expect(audio.groupID == "aud")
        #expect(audio.language == "en")
        #expect(audio.isDefault)
        #expect(audio.playlistURL?.absoluteString == "https://cdn.example.com/video/audio/en.m3u8")

        let subs = try #require(stream.subtitleTracks.first)
        #expect(subs.kind == .subtitle)
        #expect(subs.isDefault == false)
        #expect(subs.playlistURL?.absoluteString == "https://cdn.example.com/video/subs/en.m3u8")
    }

    // MARK: Media playlist

    @Test("Parses a VOD media playlist into ordered, resolved segments")
    func parsesMediaPlaylist() throws {
        let media = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:9.009,
        seg0.ts
        #EXTINF:9.009,
        seg1.ts
        #EXTINF:3.003,
        seg2.ts
        #EXT-X-ENDLIST
        """
        let mediaBase = URL(string: "https://cdn.example.com/video/720p.m3u8")!
        let stream = try HLSParser.parse(media, baseURL: mediaBase)

        #expect(stream.needsVariantResolution == false)
        let variant = try #require(stream.variants.first)
        #expect(variant.segments.count == 3)
        #expect(variant.segments.map(\.id) == [0, 1, 2])
        #expect(variant.segments[0].url.absoluteString == "https://cdn.example.com/video/seg0.ts")
        #expect(variant.segments[2].duration == 3.003)
        #expect(abs(variant.duration - 21.021) < 0.0001)
        #expect(variant.segments[0].encryption.method == .none)
    }

    @Test("Honours EXT-X-MEDIA-SEQUENCE for the first segment id")
    func honoursMediaSequence() throws {
        let media = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:100
        #EXTINF:4.0,
        a.ts
        #EXTINF:4.0,
        b.ts
        #EXT-X-ENDLIST
        """
        let stream = try HLSParser.parse(media, baseURL: base)
        #expect(stream.variants.first?.segments.map(\.id) == [100, 101])
    }

    // MARK: Encryption

    @Test("AES-128 key applies to subsequent segments, with the IV parsed to 16 bytes")
    func parsesAES128() throws {
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k.bin",IV=0x00000000000000000000000000000001
        #EXTINF:10.0,
        seg0.ts
        #EXTINF:10.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        let stream = try HLSParser.parse(media, baseURL: base)
        let segment = try #require(stream.variants.first?.segments.first)
        #expect(segment.encryption.method == .aes128)
        #expect(segment.encryption.keyURL?.absoluteString == "https://keys.example.com/k.bin")
        #expect(segment.encryption.iv?.count == 16)
        #expect(segment.encryption.iv?.last == 1)
        #expect(segment.encryption.isDecryptable)
        #expect(stream.encryptionMethods == [.aes128])
    }

    @Test("SAMPLE-AES is recorded as encrypted-but-unsupported, never cleartext")
    func recordsSampleAES() throws {
        let media = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key"
        #EXTINF:6.0,
        seg0.ts
        #EXT-X-ENDLIST
        """
        let stream = try HLSParser.parse(media, baseURL: base)
        let segment = try #require(stream.variants.first?.segments.first)
        #expect(segment.encryption.method == .sampleAES)
        #expect(segment.encryption.isDecryptable == false)
    }

    // MARK: Byte ranges & fMP4

    @Test("Byte-range segments resolve, and a missing offset continues from the previous range")
    func parsesByteRanges() throws {
        let media = """
        #EXTM3U
        #EXT-X-VERSION:4
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:1000@0
        video.mp4
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:1000
        video.mp4
        #EXT-X-ENDLIST
        """
        let stream = try HLSParser.parse(media, baseURL: base)
        let segments = try #require(stream.variants.first?.segments)
        #expect(segments.count == 2)
        #expect(segments[0].byteRange == MediaByteRange(offset: 0, length: 1000))
        #expect(segments[0].byteRange?.end == 999)
        // Second segment omits @offset, so it continues right after the first range.
        #expect(segments[1].byteRange == MediaByteRange(offset: 1000, length: 1000))
        #expect(segments[1].url.absoluteString == "https://cdn.example.com/video/video.mp4")
    }

    @Test("A negative or zero-length byte range is rejected, not turned into an invalid range")
    func rejectsMalformedByteRange() throws {
        let media = """
        #EXTM3U
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:-100@50
        a.mp4
        #EXTINF:10.0,
        #EXT-X-BYTERANGE:0@0
        b.mp4
        #EXT-X-ENDLIST
        """
        // Dropping an invalid range would download a whole resource as a segment. Fail instead.
        #expect(throws: MediaParseError.self) { _ = try HLSParser.parse(media, baseURL: base) }
    }

    @Test("EXT-X-MAP becomes the variant's fMP4 init segment")
    func parsesInitSegment() throws {
        let media = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:6.0,
        seg0.m4s
        #EXTINF:6.0,
        seg1.m4s
        #EXT-X-ENDLIST
        """
        let stream = try HLSParser.parse(media, baseURL: base)
        let variant = try #require(stream.variants.first)
        #expect(variant.initSegment?.url.absoluteString == "https://cdn.example.com/video/init.mp4")
        #expect(variant.segments.count == 2)
    }

    // MARK: Errors & scalars

    @Test("A file without #EXTM3U is rejected")
    func rejectsNonPlaylist() {
        #expect(throws: MediaParseError.notAPlaylist) {
            _ = try HLSParser.parse("just some text\nhttp://x/y", baseURL: base)
        }
    }

    @Test("A playlist with no variants or segments is rejected")
    func rejectsEmptyPlaylist() {
        #expect(throws: MediaParseError.noContent) {
            _ = try HLSParser.parse("#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-ENDLIST", baseURL: base)
        }
    }

    @Test("Attribute list parsing respects quotes")
    func parsesAttributes() {
        let attrs = HLSParser.parseAttributeList(#"BANDWIDTH=123,CODECS="a,b,c",RESOLUTION=1x2,NAME="x""#)
        #expect(attrs["BANDWIDTH"] == "123")
        #expect(attrs["CODECS"] == "a,b,c")
        #expect(attrs["RESOLUTION"] == "1x2")
        #expect(attrs["NAME"] == "x")
    }
}
