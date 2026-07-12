import Foundation
import Testing
@testable import DownloadModels

/// The media-sniffer fixture corpus — real-world streaming layouts and noise cases, exercised
/// case-for-case so the classification/dedupe heuristics stay exact.
@Suite("Media sniffer — classification")
struct MediaSnifferClassificationTests {
    @Test func classifyByURLRecognisesStreamsVideoAudioAndSkipsNonMedia() {
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/master.m3u8")?.type == .stream)
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/manifest.mpd")?.type == .stream)
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/movie.mp4")?.type == .video)
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/song.mp3")?.type == .audio)
        #expect(MediaSniffer.classifyByURL("https://example.com/index.html") == nil)
        #expect(MediaSniffer.classifyByURL("https://example.com/logo.png") == nil)
    }

    @Test func classifyByURLDropsAdaptiveSegmentChunks() {
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/seg00042.ts") == nil)
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/chunk-9.m4s") == nil)
    }

    @Test func classifyByURLRecognisesPlainDownloadableFiles() {
        #expect(MediaSniffer.classifyByURL("https://example.com/release/tool-1.2.dmg")?.type == .file)
        #expect(MediaSniffer.classifyByURL("https://example.com/docs/manual.pdf")?.type == .file)
        #expect(MediaSniffer.classifyByURL("https://example.com/src/archive.tar.gz")?.type == .file)
    }

    @Test func uiNotificationSoundsAreFilteredByGenericBasename() {
        for name in ["open", "success", "failure", "no_input", "notification", "click"] {
            #expect(MediaSniffer.classifyByURL("https://www.youtube.com/s/desktop/xyz/\(name).mp3") == nil,
                    "\(name).mp3 should be filtered as a UI sound")
        }
        // A real, non-generically-named audio file is kept.
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/podcast-episode-12.mp3")?.type == .audio)
    }

    @Test func beaconsAndGooglevideoChunksAreNoise() {
        #expect(MediaSniffer.isNoise("https://www.youtube.com/generate_204"))
        #expect(MediaSniffer.isNoise("https://youtube.com/api/stats/qoe?event=streamingstats"))
        #expect(MediaSniffer.isNoise("https://r5---sn-abc.googlevideo.com/videoplayback?itag=137"))
        #expect(!MediaSniffer.isNoise("https://cdn.example.com/movie.mp4"))
    }

    @Test func thirdPartyAdNetworkMediaIsNoiseButRealCDNMediaIsKept() {
        // Video ads from ad-network / ad-exchange / video-ad-server hosts (and any subdomain) are
        // advertisements, never the page's own content — dropped from the shelf and never taken over.
        for adURL in [
            "https://s0.2mdn.net/video/ad/creative-1080p.mp4",
            "https://securepubads.g.doubleclick.net/gampad/ads?sz=640x480",
            "https://imasdk.googleapis.com/video/preroll.mp4",
            "https://pagead2.googlesyndication.com/pagead/ad.mp4",
            "https://ads.adnxs.com/preroll.mp4",
            "https://cdn.teads.tv/media/video-ad.mp4",
            "https://cdn.fwmrm.net/ad/creative.mp4",
            "https://cdn.stickyadstv.com/prime-time/creative.mp4",
            "https://ads.exoclick.com/video/banner.mp4",
            "https://media.trafficjunky.net/preroll-720p.mp4",
            "https://delivery.propellerads.com/pop/clip.mp4",
            "https://player.mgid.com/widget/teaser.mp4"
        ] {
            #expect(MediaSniffer.isNoise(adURL), "\(adURL) is an ad")
            #expect(MediaSniffer.classifyByURL(adURL) == nil, "\(adURL) must not be a grabbable item")
            #expect(!MediaSniffer.interceptable(adURL, filename: "", mime: "video/mp4"), "\(adURL) must not be taken over")
        }
        // Look-alike shared hosts serving real content are NOT blocked: Google Cloud Storage assets
        // (imasdk/adservice are specific subdomains, not the whole parent) and any ordinary CDN.
        #expect(!MediaSniffer.isNoise("https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd"))
        #expect(MediaSniffer.classifyByURL("https://storage.googleapis.com/bucket/movie.mp4")?.type == .video)
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/movie.mp4")?.type == .video)
    }

    @Test func byteWindowedChunkFetchesAreNoise() {
        // Facebook/Instagram-style ranged media fetches assemble a file in the player; each URL is
        // a partial chunk, never a standalone download.
        #expect(MediaSniffer.isNoise("https://video.xx.fbcdn.net/v/t42/clip.mp4?bytestart=0&byteend=524287&efg=abc"))
        #expect(MediaSniffer.isNoise("https://cdn.example.com/seg/video.mp4?range=0-1023"))
        // A whole-file URL — even with unrelated query params, or "range" in a non-window form — is kept.
        #expect(!MediaSniffer.isNoise("https://cdn.example.com/movie.mp4?token=abc&expires=99"))
        #expect(!MediaSniffer.isNoise("https://cdn.example.com/free-range-farming.mp4?range=full"))
    }

    @Test func subKilobyteMediaIsNoiseByContentLength() {
        #expect(MediaSniffer.classifyByContentType("https://x.com/blip", contentType: "audio/mpeg", contentLength: 512) == nil)
        #expect(MediaSniffer.classifyByContentType(
            "https://x.com/real", contentType: "audio/mpeg", contentLength: 4_000_000)?.type == .audio)
    }

    @Test func classifyByContentTypeHandlesExtensionlessManifestsAndMedia() {
        #expect(MediaSniffer.classifyByContentType(
            "https://x.com/live?id=9", contentType: "application/vnd.apple.mpegurl")?.type == .stream)
        #expect(MediaSniffer.classifyByContentType("https://x.com/live?id=9", contentType: "application/dash+xml")?.type == .stream)
        #expect(MediaSniffer.classifyByContentType("https://x.com/hls?id=9", contentType: "audio/mpegurl")?.type == .stream)
        #expect(MediaSniffer.classifyByContentType("https://x.com/hls?id=9", contentType: "audio/x-mpegurl")?.type == .stream)
        #expect(MediaSniffer.classifyByContentType("https://x.com/v?id=9", contentType: "video/mp4")?.type == .video)
        #expect(MediaSniffer.classifyByContentType("https://x.com/a?id=9", contentType: "audio/mp4")?.type == .audio)
        #expect(MediaSniffer.classifyByContentType("https://x.com/p?id=9", contentType: "text/html") == nil)
    }

    @Test func attachmentFilenameParsesRFC5987QuotedAndBareForms() {
        #expect(MediaSniffer.attachmentFilename("attachment; filename=\"report final.pdf\"") == "report final.pdf")
        #expect(MediaSniffer.attachmentFilename("attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf") == "résumé.pdf")
        // RFC 5987 allows a language tag in the middle slot.
        #expect(MediaSniffer.attachmentFilename("attachment; filename*=UTF-8'en'r%C3%A9sum%C3%A9.pdf") == "résumé.pdf")
        #expect(MediaSniffer.attachmentFilename("attachment; filename=plain.zip") == "plain.zip")
        #expect(MediaSniffer.attachmentFilename("attachment") == "")
        #expect(MediaSniffer.attachmentFilename("inline; filename=\"preview.pdf\"") == nil)
        #expect(MediaSniffer.attachmentFilename("") == nil)
    }

    @Test func attachmentDispositionIsTrustedAndItsFilenameWinsOverTheURL() {
        let item = MediaSniffer.classifyByContentType(
            "https://api.example.com/export?id=7", contentType: "application/octet-stream",
            contentLength: 5_000_000, contentDisposition: "attachment; filename=\"dataset-2026.zip\"")
        #expect(item?.type == .file)
        #expect(item?.filename == "dataset-2026.zip")
        // Attachment with a media filename classifies as that media type.
        let media = MediaSniffer.classifyByContentType(
            "https://api.example.com/dl?id=9", contentType: "application/octet-stream",
            contentLength: 9_000_000, contentDisposition: "attachment; filename=\"clip.mp4\"")
        #expect(media?.type == .video)
    }

    @Test func fileMIMEsRecognisedBareOctetStreamIgnored() {
        #expect(MediaSniffer.classifyByContentType(
            "https://x.com/get?id=1", contentType: "application/zip", contentLength: 1_000_000)?.type == .file)
        #expect(MediaSniffer.classifyByContentType(
            "https://x.com/get?id=2", contentType: "application/pdf", contentLength: 200_000)?.type == .file)
        #expect(MediaSniffer.classifyByContentType(
            "https://x.com/api/blob", contentType: "application/octet-stream", contentLength: 1_000_000) == nil)
    }

    @Test func recordKeyFoldsSignedTokenRotationKeepsQueryIdentityForExtensionless() {
        let first = MediaSniffer.recordKey("https://cdn.example.com/v/movie.mp4?token=AAA&exp=1")
        let second = MediaSniffer.recordKey("https://cdn.example.com/v/movie.mp4?token=BBB&exp=2")
        #expect(first == second)
        let x = MediaSniffer.recordKey("https://host.example.com/videoplayback?id=X")
        let y = MediaSniffer.recordKey("https://host.example.com/videoplayback?id=Y")
        #expect(x != y)
    }

    @Test func cmafChunkExtensionsAreSegments() {
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/s/seg_5.cmfv") == nil)
        #expect(MediaSniffer.classifyByURL("https://cdn.example.com/s/seg_5.cmfa") == nil)
    }

    @Test func videoKeyIsNilWithoutRenditionStructure() {
        #expect(MediaSniffer.videoKey("https://cdn.example.com/movie.mp4") == nil)
        #expect(MediaSniffer.videoKey("https://cdn.example.com/a/b/song.mp3") == nil)
        #expect(MediaSniffer.videoKey("https://cdn.example.com/v/vid/720x1280/x.mp4") != nil)
    }

    @Test func urlPieceHelpers() {
        #expect(MediaSniffer.hostOf("https://a.b.com/x/y.mp4?q=1") == "a.b.com")
        #expect(MediaSniffer.extensionOf("https://a.com/x/y.MP4") == "mp4")
        #expect(MediaSniffer.fileNameFromURL("https://a.com/x/My%20Clip.mp4") == "My Clip.mp4")
        #expect(MediaSniffer.audioExt("opus"))
        #expect(!MediaSniffer.audioExt("mp4"))
    }

    @Test func interceptableKnownFileMediaTypesByURLFilenameOrMIMENothingElse() {
        #expect(MediaSniffer.interceptable("https://example.com/tool.dmg", filename: "", mime: ""))
        #expect(MediaSniffer.interceptable("https://example.com/get?id=1", filename: "movie.mkv", mime: ""))
        #expect(MediaSniffer.interceptable("https://example.com/get?id=2", filename: "", mime: "application/zip"))
        #expect(MediaSniffer.interceptable("https://example.com/get?id=3", filename: "", mime: "video/mp4"))
        #expect(!MediaSniffer.interceptable("https://example.com/page", filename: "", mime: "text/html"))
        #expect(!MediaSniffer.interceptable("https://example.com/api/blob", filename: "", mime: "application/octet-stream"))
        #expect(!MediaSniffer.interceptable("blob:https://example.com/uuid", filename: "clip.mp4", mime: ""))
        #expect(!MediaSniffer.interceptable("https://example.com/photo", filename: "img.jpeg", mime: "image/jpeg"))
    }
}

@Suite("Media sniffer — dedupe cascade")
struct MediaSnifferDedupeTests {
    private func item(_ url: String, _ type: SniffedItem.ItemType) -> SniffedItem { SniffedItem(url: url, type: type) }
    private func pageItem(_ url: String) -> SniffedItem { SniffedItem(url: url, type: .page, label: "Title", extract: true) }

    @Test func removesDuplicateURLsAndOrdersStreamVideoAudioFile() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://x.com/a.mp3", .audio),
            item("https://x.com/v.mp4", .video),
            item("https://x.com/m.m3u8", .stream),
            item("https://x.com/a.mp3", .audio),   // dup
            item("https://x.com/f.zip", .file)
        ])
        #expect(items.map(\.type) == [.stream, .video, .audio, .file])
    }

    @Test func collapsesXStyleRenditionVariantsToTheMasterStream() {
        let base = "https://video.twimg.com/ext_tw_video/1900000000000000000/pu"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/pl/master.m3u8", .stream),                 // master playlist
            item("\(base)/vid/avc1/480x270/a.m3u8", .stream),        // variant playlists
            item("\(base)/vid/avc1/720x1280/b.m3u8", .stream),
            item("\(base)/vid/avc1/1280x720/c.m3u8", .stream),
            item("\(base)/vid/avc1/480x270/a.mp4", .video),          // progressive renditions
            item("\(base)/vid/avc1/720x1280/b.mp4", .video),
            item("\(base)/vid/avc1/1280x720/c.mp4", .video)
        ])
        #expect(items.count == 1, "one video → one entry")
        #expect(items.first?.type == .stream)
        #expect(items.first?.url.hasSuffix("/pl/master.m3u8") == true, "the master playlist is the representative")
    }

    @Test func keepsGenuinelyDifferentVideosSeparate() {
        func url(_ id: String) -> String { "https://video.twimg.com/ext_tw_video/\(id)/pu/vid/avc1/720x1280/x.mp4" }
        let items = MediaSniffer.dedupeAndRank([item(url("111"), .video), item(url("222"), .video)])
        #expect(items.count == 2)
    }

    @Test func collapsesProgressiveOnlyVariantsToTheHighestResolution() {
        let base = "https://cdn.example.com/media/clip42/vid"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/640x360/f.mp4", .video),
            item("\(base)/1920x1080/f.mp4", .video),
            item("\(base)/1280x720/f.mp4", .video)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.contains("1920x1080") == true, "the largest rendition wins")
    }

    @Test func neverMergesDistinctFilesThatMerelyShareADirectory() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/downloads/a.zip", .file),
            item("https://cdn.example.com/downloads/b.zip", .file),
            item("https://cdn.example.com/pod/ep1.mp3", .audio),
            item("https://cdn.example.com/pod/ep2.mp3", .audio)
        ])
        #expect(items.count == 4, "no rendition markers → nothing collapses")
    }

    @Test func collapsesHLSMasterPlusSiblingFolderVariantsToTheMaster() {
        let base = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/master.m3u8", .stream),
            item("\(base)/v4/prog_index.m3u8", .stream),
            item("\(base)/v9/prog_index.m3u8", .stream),
            item("\(base)/a1/prog_index.m3u8", .stream),
            item("\(base)/s1/en/prog_index.m3u8", .stream)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix("/master.m3u8") == true)
    }

    @Test func collapsesARootLevelMasterWithItsSubfolderVariantsAndSegments() {
        // The master sits at the host root — its folder key is the bare host, and the containment
        // tests must still match its /v4/ descendants.
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example/master.m3u8", .stream),
            item("https://cdn.example/v4/prog_index.m3u8", .stream),
            item("https://cdn.example/v4/fileSequence0.aac", .audio),
            item("https://cdn.example/v4/fileSequence1.aac", .audio)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix("/master.m3u8") == true)
    }

    @Test func dropsDASHMediaSegmentsWhenAManifestIsPresent() {
        let base = "https://dash.akamaized.net/akamai/bbb_30fps"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/bbb_30fps.mpd", .stream),
            item("\(base)/bbb_30fps_480x270_600k/bbb_30fps_480x270_600k_0.m4v", .video),
            item("\(base)/bbb_30fps_480x270_600k/bbb_30fps_480x270_600k_1.m4v", .video),
            item("\(base)/bbb_a64k/bbb_a64k_9.m4a", .audio),
            item("\(base)/bbb_a64k/bbb_a64k_10.m4a", .audio)
        ])
        #expect(items.map(\.type) == [.stream])
        #expect(items.first?.url.hasSuffix(".mpd") == true)
    }

    @Test func dropsHLSAACAudioSegmentsAlongsideTheMaster() {
        let base = "https://cdn.example.com/media/img_example"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/master.m3u8", .stream),
            item("\(base)/a1/fileSequence0.aac", .audio),
            item("\(base)/a1/fileSequence1.aac", .audio),
            item("\(base)/a1/fileSequence2.aac", .audio)
        ])
        #expect(items.count == 1)
        #expect(items.first?.type == .stream)
    }

    @Test func keepsNumberedMediaWhenNoManifestIsPresent() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/pod/ep1.mp3", .audio),
            item("https://cdn.example.com/pod/ep2.mp3", .audio),
            item("https://cdn.example.com/pod/ep3.mp3", .audio)
        ])
        #expect(items.count == 3, "no stream manifest → numbered files are content, not chunks")
    }

    @Test func sparesAPlainDigitEndingDownloadInAnUnrelatedFolderNextToAStream() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/feature/master.m3u8", .stream),
            item("https://cdn.example.com/promos/big-buck-bunny-2024.mp4", .video)
        ])
        #expect(items.count == 2, "the unrelated .mp4 must survive")
        #expect(items.contains { $0.url.hasSuffix("big-buck-bunny-2024.mp4") })
    }

    @Test func dropsStrongSignalSegmentsEvenOnADifferentHostThanTheManifest() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://dash.akamaized.net/dash264/TestCases/1a/netflix/exMPD_BIP_TC1.mpd", .stream),
            item("http://dash.edgesuite.net/dash264/TestCases/1a/netflix/ElephantsDream_H264BPL30_0100.264.dash", .video),
            item("http://dash.edgesuite.net/dash264/TestCases/1a/netflix/ElephantsDream_AAC48K_064.mp4.dash", .audio)
        ])
        #expect(items.map(\.type) == [.stream], "strong-signal segments must be dropped anywhere")
    }

    @Test func dropsABareDigitSuffixMediaFileInTheManifestsOwnFolder() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/d/master.m3u8", .stream),
            item("https://cdn.example.com/d/clip_7.mp4", .video)   // same folder + bare digit suffix
        ])
        #expect(items.map(\.type) == [.stream])
    }

    @Test func keepsTwoUnrelatedStreamsInNonNestedFolders() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/videoA/master.m3u8", .stream),
            item("https://cdn.example.com/videoB/master.m3u8", .stream)
        ])
        #expect(items.count == 2)
    }

    @Test func collapsesSameFolderVariantsToTheEmptyStemMasterUnifiedStreaming() {
        let base = "https://demo.unified-streaming.com/video/tears-of-steel/tears-of-steel.ism"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/.m3u8", .stream),                                          // master, empty stem
            item("\(base)/tears-of-steel-audio_eng=64008-video_eng=401000.m3u8", .stream),
            item("\(base)/tears-of-steel-audio_eng=128002-video_eng=1501000.m3u8", .stream),
            item("\(base)/tears-of-steel-audio_eng=128002-video_eng=1001000.m3u8", .stream)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix("/.m3u8") == true)
    }

    @Test func collapsesMasterPlusSameFolderAltAudioRenditionToTheMaster() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/d/master.m3u8", .stream),
            item("https://cdn.example.com/d/audio_eng.m3u8", .stream)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix("/master.m3u8") == true)
    }

    @Test func doesNotCollapseTwoMasterNamedStreamsInTheSameFolder() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/d/movie1.m3u8", .stream),
            item("https://cdn.example.com/d/movie2.m3u8", .stream)
        ])
        #expect(items.count == 2)
    }

    @Test func collapsesSameFolderVariantsToAMarkedlyShorterMasterNameShaka() {
        let base = "https://storage.googleapis.com/shaka-demo-assets/angel-one-hls"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/hls.m3u8", .stream),                                  // master, short stem
            item("\(base)/playlist_v-0360p-0750k-libx264.mp4.m3u8", .stream),
            item("\(base)/playlist_a-eng-0128k-aac-2c.mp4.m3u8", .stream),
            item("\(base)/playlist_s-en.webvtt.m3u8", .stream),
            item("\(base)/v-0360p-0750k-libx264-init.mp4", .video),            // init segments
            item("\(base)/a-eng-0128k-aac-2c-init.mp4", .video)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix("/hls.m3u8") == true)
    }

    @Test func dropsUnnumberedDASHTrackFilesUnderAManifestFolder() {
        let base = "https://storage.googleapis.com/shaka-demo-assets/angel-one"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/dash.mpd", .stream),
            item("\(base)/audio_en_2c_64k_opus.webm", .audio),
            item("\(base)/text_el.mp4", .video)
        ])
        #expect(items.map(\.type) == [.stream])
    }

    @Test func dropsInitSegmentsInNumberedSubfoldersUnderAManifest() {
        let base = "https://media.axprod.net/TestVectors/v7-Clear"
        let items = MediaSniffer.dedupeAndRank([
            item("\(base)/Manifest_1080p.mpd", .stream),
            item("\(base)/2/init.mp4", .video),
            item("\(base)/15/init.mp4", .video),
            item("\(base)/1/init.mp4", .audio)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix(".mpd") == true)
    }

    @Test func keepsTwoDistinctVideosOnOnePage() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://a-cdn.example.com/showA/master.m3u8", .stream),
            item("https://b-cdn.example.com/showB/master.m3u8", .stream)
        ])
        #expect(items.count == 2)
    }

    @Test func dedupesTheSameDistinctiveFileMirroredAcrossHosts() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://archive.org/serve/BBB/big_buck_bunny_720p_surround.mp4", .video),
            item("https://dn80.us.archive.org/0/items/BBB/big_buck_bunny_720p_surround.mp4?cnt=0", .video)
        ])
        #expect(items.count == 1)
    }

    @Test func doesNotDedupeGenericSameNamedFilesAcrossHosts() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://a.example.com/video.mp4", .video),
            item("https://b.example.com/video.mp4", .video)
        ])
        #expect(items.count == 2)
    }

    @Test func foldsTheHLSDASHTwinOfOneAssetSameStemSameFolder() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/vod/video.m3u8", .stream),
            item("https://cdn.example.com/vod/video.mpd", .stream)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix(".m3u8") == true, "HLS wins the twin")
    }

    @Test func foldsAMasterNamedHLSDASHPair() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/asset42/manifest.mpd", .stream),
            item("https://cdn.example.com/asset42/master.m3u8", .stream)
        ])
        #expect(items.count == 1)
        #expect(items.first?.url.hasSuffix(".m3u8") == true)
    }

    @Test func bitmovinStyleContainerSiblingFoldersCollapseToOneStream() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/content/art-of-motion/m3u8s/f08e80da.m3u8", .stream),
            item("https://cdn.example.com/content/art-of-motion/mpds/f08e80da.mpd", .stream)
        ])
        #expect(items.count == 1)
    }

    @Test func twoDifferentAssetsInOneFolderNeverCollapse() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://cdn.example.com/vod/movie-one.m3u8", .stream),
            item("https://cdn.example.com/vod/movie-two.m3u8", .stream)
        ])
        #expect(items.count == 2)
    }

    @Test func aSniffedStreamSuppressesThePageExtractionItem() {
        let items = MediaSniffer.dedupeAndRank([
            pageItem("https://site.example.com/watch/42"),
            item("https://cdn.example.com/vod/master.m3u8", .stream)
        ])
        #expect(items.count == 1)
        #expect(items.first?.type == .stream)
    }

    @Test func thePageExtractionItemSurvivesAndRanksFirstWithoutAStream() {
        let items = MediaSniffer.dedupeAndRank([
            item("https://site.example.com/podcast/ep1.mp3", .audio),
            pageItem("https://site.example.com/watch/42")
        ])
        #expect(items.count == 2)
        #expect(items.first?.type == .page)
    }
}

@Suite("Media sniffer — primary player")
struct MediaSnifferPrimaryPlayerTests {
    private func player(video: Bool, area: Double) -> MediaSniffer.SniffedPlayer { .init(video: video, area: area) }

    @Test func picksTheLargestVideo() {
        #expect(MediaSniffer.primaryPlayerIndex([
            player(video: true, area: 200 * 120),
            player(video: true, area: 1280 * 720),
            player(video: true, area: 300 * 200)
        ]) == 1)
    }

    @Test func aVideoAlwaysOutranksALargerAudio() {
        #expect(MediaSniffer.primaryPlayerIndex([
            player(video: false, area: 5000 * 5000),   // huge audio element
            player(video: true, area: 180 * 120)       // small video still wins
        ]) == 1)
    }

    @Test func fallsBackToTheLargestAudioWhenThereIsNoVideo() {
        #expect(MediaSniffer.primaryPlayerIndex([
            player(video: false, area: 100),
            player(video: false, area: 900),
            player(video: false, area: 400)
        ]) == 1)
    }

    @Test func emptyListIsMinusOneAndTiesKeepTheFirst() {
        #expect(MediaSniffer.primaryPlayerIndex([]) == -1)
        #expect(MediaSniffer.primaryPlayerIndex([player(video: true, area: 100), player(video: true, area: 100)]) == 0)
    }

    @Test func youTubeMainPlayerWinsOverPreviewAndMiniplayerVideos() {
        let players = [
            player(video: true, area: 854 * 480),   // main player
            player(video: true, area: 168 * 94),    // sidebar hover preview
            player(video: true, area: 168 * 94),    // another preview
            player(video: true, area: 400 * 225)    // miniplayer
        ]
        #expect(MediaSniffer.primaryPlayerIndex(players) == 0)
    }
}
