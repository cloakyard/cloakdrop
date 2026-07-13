import Foundation
import Testing
@testable import DownloadModels

/// The curated video-page allowlist: it must recognize the common video hosts (and their subdomains
/// / short-link domains) a user pastes, while never flagging a plain file, a look-alike domain, or a
/// bare site root — precision matters, because a match reroutes the download to the media extractor.
@Suite("Video page detection")
struct VideoPageDetectorTests {

    private func url(_ string: String) -> URL { URL(string: string)! }

    @Test("Recognizes a YouTube watch page")
    func youtubeWatch() {
        #expect(VideoPageDetector.detect(url("https://www.youtube.com/watch?v=Y_1ioNxTc1U"))?.displayName == "YouTube")
    }

    @Test("Recognizes youtu.be short links and the m. subdomain")
    func youtubeVariants() {
        #expect(VideoPageDetector.detect(url("https://youtu.be/Y_1ioNxTc1U"))?.displayName == "YouTube")
        #expect(VideoPageDetector.detect(url("https://m.youtube.com/watch?v=abc"))?.displayName == "YouTube")
        #expect(VideoPageDetector.detect(url("https://music.youtube.com/watch?v=abc"))?.displayName == "YouTube")
    }

    @Test("Recognizes other curated sites")
    func otherSites() {
        #expect(VideoPageDetector.detect(url("https://vimeo.com/123456789"))?.displayName == "Vimeo")
        #expect(VideoPageDetector.detect(url("https://www.tiktok.com/@user/video/123"))?.displayName == "TikTok")
        #expect(VideoPageDetector.detect(url("https://x.com/user/status/123"))?.displayName == "X")
        #expect(VideoPageDetector.detect(url("https://twitter.com/user/status/123"))?.displayName == "X")
        #expect(VideoPageDetector.detect(url("https://dai.ly/x8abcde"))?.displayName == "Dailymotion")
    }

    @Test("A plain file URL is not a video page")
    func plainFile() {
        #expect(VideoPageDetector.detect(url("https://example.com/file.zip")) == nil)
        #expect(VideoPageDetector.detect(url("https://cdn.example.com/video.mp4")) == nil)
    }

    @Test("Look-alike domains never match")
    func lookAlikes() {
        #expect(VideoPageDetector.detect(url("https://evilyoutube.com/watch?v=abc")) == nil)
        #expect(VideoPageDetector.detect(url("https://youtube.com.attacker.net/watch?v=abc")) == nil)
        #expect(VideoPageDetector.detect(url("https://notvimeo.com/123")) == nil)
    }

    @Test("A bare site root is not offered as a grab")
    func siteRoot() {
        #expect(VideoPageDetector.detect(url("https://www.youtube.com/")) == nil)
        #expect(VideoPageDetector.detect(url("https://youtube.com")) == nil)
    }

    @Test("A non-web scheme is never a video page")
    func nonWebScheme() {
        #expect(VideoPageDetector.detect(url("ftp://youtube.com/watch?v=abc")) == nil)
        #expect(VideoPageDetector.detect(url("file:///vimeo.com/123")) == nil)
        // http is fine, not just https.
        #expect(VideoPageDetector.detect(url("http://www.youtube.com/watch?v=abc"))?.displayName == "YouTube")
    }
}
