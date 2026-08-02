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
        #expect(VideoPageDetector.detect(url("https://www.youtube.com/shorts/abc"))?.displayName == "YouTube")
        #expect(VideoPageDetector.detect(url("https://www.youtube-nocookie.com/embed/abc"))?.displayName == "YouTube")
    }

    @Test("Recognizes other curated sites")
    func otherSites() {
        #expect(VideoPageDetector.detect(url("https://vimeo.com/123456789"))?.displayName == "Vimeo")
        #expect(VideoPageDetector.detect(url("https://www.tiktok.com/@user/video/123"))?.displayName == "TikTok")
        #expect(VideoPageDetector.detect(url("https://x.com/user/status/123"))?.displayName == "X")
        #expect(VideoPageDetector.detect(url("https://twitter.com/user/status/123"))?.displayName == "X")
        #expect(VideoPageDetector.detect(url("https://dai.ly/x8abcde"))?.displayName == "Dailymotion")
        #expect(VideoPageDetector.detect(url("https://www.instagram.com/reel/ABC123/"))?.displayName == "Instagram")
        #expect(VideoPageDetector.detect(url("https://www.reddit.com/r/videos/comments/abc123/title/"))?.displayName == "Reddit")
    }

    @Test("Recognizes major anime watch routes supported by the bundled extractor")
    func animeSites() {
        #expect(VideoPageDetector.detect(url("https://www.bilibili.com/video/BV1xx411c7mD"))?.displayName == "Bilibili")
        #expect(VideoPageDetector.detect(url("https://www.bilibili.com/bangumi/play/ep123456"))?.displayName == "Bilibili")
        #expect(VideoPageDetector.detect(url("https://b23.tv/AbCd123"))?.displayName == "Bilibili")
        #expect(VideoPageDetector.detect(url("https://www.nicovideo.jp/watch/sm8628149"))?.displayName == "Niconico")
        #expect(VideoPageDetector.detect(url("https://www.acfun.cn/v/ac35457073"))?.displayName == "AcFun")
        #expect(VideoPageDetector.detect(url("https://www.acfun.cn/bangumi/aa6002917_36188_1745457"))?.displayName == "AcFun")
        #expect(VideoPageDetector.detect(
            url("https://www.hidive.com/stream/the-comic-artist-and-his-assistants/s01e001")
        )?.displayName == "HIDIVE")
    }

    @Test("Recognizes additional single-item routes proven against the bundled resolver")
    func expandedSingleMediaSites() {
        let cases = [
            ("https://rumble.com/embed/v5pv5f", "Rumble"),
            ("https://rumble.com/vdmum1-moose-the-dog.html", "Rumble"),
            ("https://odysee.com/@channel:1/video:e", "Odysee"),
            ("https://www.ted.com/talks/a_public_talk", "TED"),
            ("https://www.loom.com/share/43d05f362f734614a2e81b4694a3a523", "Loom"),
            ("https://medal.tv/games/valorant/clips/jTBFnLKdLy15K", "Medal"),
            ("https://artist.bandcamp.com/track/a-song", "Bandcamp"),
            ("https://www.mixcloud.com/artist/a-mix/", "Mixcloud"),
            ("https://kick.com/user/videos/5c697a87-afce-4256-b01f-3c8fe71ef5cb", "Kick"),
            ("https://kick.com/user?clip=clip_123", "Kick"),
            ("https://vk.com/video205387401_165548505", "VK"),
            ("https://vk.com/video_ext.php?oid=-77521&id=162222515", "VK"),
            ("https://www.snapchat.com/spotlight/ABC123", "Snapchat"),
        ]
        for (string, expected) in cases {
            #expect(VideoPageDetector.detect(url(string))?.displayName == expected, "missed \(string)")
        }
    }

    @Test("Browser strategy distinguishes mixed posts and unreliable page endpoints")
    func browserStrategies() {
        #expect(VideoPageDetector.detect(url("https://x.com/user/status/123"))?.requiresObservedMedia == true)
        #expect(VideoPageDetector.detect(url("https://x.com/user/status/123"))?.prefersObservedMedia == true)
        #expect(VideoPageDetector.detect(url("https://www.instagram.com/p/ABC123/"))?.requiresObservedMedia == true)
        #expect(VideoPageDetector.detect(url("https://www.instagram.com/p/ABC123/"))?.prefersObservedMedia == true)
        #expect(VideoPageDetector.detect(url("https://www.tiktok.com/@user/video/123"))?.prefersObservedMedia == true)
        #expect(VideoPageDetector.detect(url("https://www.facebook.com/reel/123"))?.prefersObservedMedia == true)
    }

    @Test("Recognizes current popular single-post and hosted-video routes")
    func currentPopularRoutes() {
        let cases = [
            ("https://clips.twitch.tv/AwkwardHelplessSalamanderSwiftRage", "Twitch"),
            ("https://www.twitch.tv/creator/clip/AwkwardClip", "Twitch"),
            ("https://streamable.com/dnd1", "Streamable"),
            ("https://archive.org/details/Cops1922", "Internet Archive"),
            ("https://maskofthedragon.tumblr.com/post/626907179849564160/video", "Tumblr"),
            ("https://imgur.com/A61SaA1", "Imgur"),
            ("https://www.flickr.com/photos/forestwander/5645318632/", "Flickr"),
            ("https://www.linkedin.com/posts/creator_video-activity-7151241570371948544", "LinkedIn"),
            ("https://www.pinterest.com/pin/664281013778109217/", "Pinterest"),
            ("https://9gag.com/gag/ae5Ag7B", "9GAG"),
            ("https://bsky.app/profile/bsky.app/post/3l3vgf77uco2g", "Bluesky"),
            ("https://rutube.ru/video/3eac3b4561676c17df9132a9a1e62e3e/", "Rutube"),
            ("https://fast.wistia.net/embed/iframe/807fafadvk", "Wistia"),
        ]
        for (string, expected) in cases {
            #expect(VideoPageDetector.detect(url(string))?.displayName == expected, "missed \(string)")
        }
        #expect(VideoPageDetector.detect(url("https://i.imgur.com/A61SaA1.mp4")) == nil,
                "a direct media file must stay a direct download")
    }

    @Test("Feed, profile, search, and collection pages never become multi-file grabs")
    func nonVideoRoutes() {
        for string in [
            "https://www.youtube.com/@creator/videos",
            "https://www.youtube.com/feed/subscriptions",
            "https://www.youtube.com/watch",
            "https://vimeo.com/channels/staffpicks",
            "https://www.tiktok.com/@creator",
            "https://x.com/creator",
            "https://www.facebook.com/watch/",
            "https://www.instagram.com/creator/",
            "https://www.reddit.com/r/videos/",
            "https://soundcloud.com/creator/sets/album",
            "https://www.bilibili.com/anime/",
            "https://www.hidive.com/dashboard",
            "https://rumble.com/c/creator",
            "https://odysee.com/@creator:1",
            "https://www.ted.com/playlists/171/popular",
            "https://www.loom.com/team-videos",
            "https://medal.tv/games/valorant",
            "https://www.nicovideo.jp/user/123/videos",
            "https://artist.bandcamp.com/album/an-album",
            "https://www.mixcloud.com/artist/uploads/",
            "https://kick.com/categories/gaming",
            "https://vk.com/videos-77521",
            "https://www.snapchat.com/discover",
            "https://archive.org/details",
            "https://www.tumblr.com/explore/trending",
            "https://imgur.com/gallery",
            "https://www.flickr.com/photos/creator/albums",
            "https://www.linkedin.com/in/creator",
            "https://www.pinterest.com/creator/boards",
            "https://9gag.com/hot",
            "https://bsky.app/profile/bsky.app",
            "https://rutube.ru/channel/123",
            "https://www.acfun.cn/u/123",
            "https://www.hidive.com/video/737494"
        ] {
            #expect(VideoPageDetector.detect(url(string)) == nil, "\(string) is not one video")
        }
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
