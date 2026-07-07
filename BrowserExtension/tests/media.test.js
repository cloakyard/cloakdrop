// Zero-dependency tests for the shared media core, run with the Node built-in runner:
//   node --test BrowserExtension/tests/
// media.js is a classic browser script that also `module.exports`es under Node (dual-export shim),
// so it is directly require-able here — no bundler, no npm install.

const test = require("node:test");
const assert = require("node:assert/strict");
const M = require("../shared/media.js");

test("classifyByURL recognises streams, video, audio and skips non-media", () => {
  assert.equal(M.classifyByURL("https://cdn.example.com/master.m3u8").type, "stream");
  assert.equal(M.classifyByURL("https://cdn.example.com/manifest.mpd").type, "stream");
  assert.equal(M.classifyByURL("https://cdn.example.com/movie.mp4").type, "video");
  assert.equal(M.classifyByURL("https://cdn.example.com/song.mp3").type, "audio");
  assert.equal(M.classifyByURL("https://example.com/index.html"), null);
  assert.equal(M.classifyByURL("https://example.com/logo.png"), null);
});

test("classifyByURL drops adaptive segment chunks", () => {
  assert.equal(M.classifyByURL("https://cdn.example.com/seg00042.ts"), null);
  assert.equal(M.classifyByURL("https://cdn.example.com/chunk-9.m4s"), null);
});

test("isNoise kills YouTube UI notification sounds by generic basename", () => {
  for (const name of ["open", "success", "failure", "no_input", "notification", "click"]) {
    assert.equal(M.classifyByURL(`https://www.youtube.com/s/desktop/xyz/${name}.mp3`), null,
      `${name}.mp3 should be filtered as a UI sound`);
  }
  // A real, non-generically-named audio file is kept.
  assert.equal(M.classifyByURL("https://cdn.example.com/podcast-episode-12.mp3").type, "audio");
});

test("isNoise drops analytics/telemetry beacons and googlevideo chunks", () => {
  assert.ok(M.isNoise("https://www.youtube.com/generate_204"));
  assert.ok(M.isNoise("https://youtube.com/api/stats/qoe?event=streamingstats"));
  assert.ok(M.isNoise("https://r5---sn-abc.googlevideo.com/videoplayback?itag=137"));
  assert.ok(!M.isNoise("https://cdn.example.com/movie.mp4"));
});

test("isNoise drops sub-1KB 'media' by content-length", () => {
  assert.equal(M.classifyByContentType("https://x.com/blip", "audio/mpeg", 512), null);
  assert.equal(M.classifyByContentType("https://x.com/real", "audio/mpeg", 4_000_000).type, "audio");
});

test("classifyByContentType handles extensionless manifests + media", () => {
  assert.equal(M.classifyByContentType("https://x.com/live?id=9", "application/vnd.apple.mpegurl").type, "stream");
  assert.equal(M.classifyByContentType("https://x.com/live?id=9", "application/dash+xml").type, "stream");
  assert.equal(M.classifyByContentType("https://x.com/v?id=9", "video/mp4").type, "video");
  assert.equal(M.classifyByContentType("https://x.com/a?id=9", "audio/mp4").type, "audio");
  assert.equal(M.classifyByContentType("https://x.com/p?id=9", "text/html"), null);
});

test("dedupeAndRank removes duplicate URLs and orders streams->video->audio->file", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://x.com/a.mp3", "audio"),
    M.makeItem("https://x.com/v.mp4", "video"),
    M.makeItem("https://x.com/m.m3u8", "stream"),
    M.makeItem("https://x.com/a.mp3", "audio"), // dup
    M.makeItem("https://x.com/f.zip", "file")
  ]);
  assert.deepEqual(items.map((i) => i.type), ["stream", "video", "audio", "file"]);
});

test("collapses X-style rendition variants of one video to a single master stream", () => {
  const id = "1900000000000000000";
  const base = `https://video.twimg.com/ext_tw_video/${id}/pu`;
  const items = M.dedupeAndRank([
    M.makeItem(`${base}/pl/master.m3u8`, "stream"),                 // master playlist
    M.makeItem(`${base}/vid/avc1/480x270/a.m3u8`, "stream"),        // variant playlists
    M.makeItem(`${base}/vid/avc1/720x1280/b.m3u8`, "stream"),
    M.makeItem(`${base}/vid/avc1/1280x720/c.m3u8`, "stream"),
    M.makeItem(`${base}/vid/avc1/480x270/a.mp4`, "video"),          // progressive renditions
    M.makeItem(`${base}/vid/avc1/720x1280/b.mp4`, "video"),
    M.makeItem(`${base}/vid/avc1/1280x720/c.mp4`, "video")
  ]);
  assert.equal(items.length, 1, "one video → one entry");
  assert.equal(items[0].type, "stream");
  assert.ok(items[0].url.endsWith("/pl/master.m3u8"), "the master playlist is the representative");
});

test("keeps genuinely different videos as separate entries", () => {
  const mk = (id) => `https://video.twimg.com/ext_tw_video/${id}/pu/vid/avc1/720x1280/x.mp4`;
  const items = M.dedupeAndRank([M.makeItem(mk("111"), "video"), M.makeItem(mk("222"), "video")]);
  assert.equal(items.length, 2);
});

test("collapses progressive-only variants to the highest resolution", () => {
  const base = "https://cdn.example.com/media/clip42/vid";
  const items = M.dedupeAndRank([
    M.makeItem(`${base}/640x360/f.mp4`, "video"),
    M.makeItem(`${base}/1920x1080/f.mp4`, "video"),
    M.makeItem(`${base}/1280x720/f.mp4`, "video")
  ]);
  assert.equal(items.length, 1);
  assert.ok(items[0].url.includes("1920x1080"), "the largest rendition wins");
});

test("never merges distinct files that merely share a directory", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/downloads/a.zip", "file"),
    M.makeItem("https://cdn.example.com/downloads/b.zip", "file"),
    M.makeItem("https://cdn.example.com/pod/ep1.mp3", "audio"),
    M.makeItem("https://cdn.example.com/pod/ep2.mp3", "audio")
  ]);
  assert.equal(items.length, 4, "no rendition markers → nothing collapses");
});

test("collapses HLS master + sibling-folder variant playlists to the master", () => {
  const base = "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts";
  const items = M.dedupeAndRank([
    M.makeItem(`${base}/master.m3u8`, "stream"),
    M.makeItem(`${base}/v4/prog_index.m3u8`, "stream"),
    M.makeItem(`${base}/v9/prog_index.m3u8`, "stream"),
    M.makeItem(`${base}/a1/prog_index.m3u8`, "stream"),
    M.makeItem(`${base}/s1/en/prog_index.m3u8`, "stream")
  ]);
  assert.equal(items.length, 1);
  assert.ok(items[0].url.endsWith("/master.m3u8"));
});

test("drops DASH media segments (numbered .m4v/.m4a) when a manifest is present", () => {
  const b = "https://dash.akamaized.net/akamai/bbb_30fps";
  const items = M.dedupeAndRank([
    M.makeItem(`${b}/bbb_30fps.mpd`, "stream"),
    M.makeItem(`${b}/bbb_30fps_480x270_600k/bbb_30fps_480x270_600k_0.m4v`, "video"),
    M.makeItem(`${b}/bbb_30fps_480x270_600k/bbb_30fps_480x270_600k_1.m4v`, "video"),
    M.makeItem(`${b}/bbb_a64k/bbb_a64k_9.m4a`, "audio"),
    M.makeItem(`${b}/bbb_a64k/bbb_a64k_10.m4a`, "audio")
  ]);
  assert.deepEqual(items.map((i) => i.type), ["stream"]);
  assert.ok(items[0].url.endsWith(".mpd"));
});

test("drops HLS .aac audio segments (fileSequenceN) alongside the master", () => {
  const b = "https://cdn.example.com/media/img_example";
  const items = M.dedupeAndRank([
    M.makeItem(`${b}/master.m3u8`, "stream"),
    M.makeItem(`${b}/a1/fileSequence0.aac`, "audio"),
    M.makeItem(`${b}/a1/fileSequence1.aac`, "audio"),
    M.makeItem(`${b}/a1/fileSequence2.aac`, "audio")
  ]);
  assert.equal(items.length, 1);
  assert.equal(items[0].type, "stream");
});

test("keeps numbered media when NO manifest is present (podcast ep1/ep2/ep3, not segments)", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/pod/ep1.mp3", "audio"),
    M.makeItem("https://cdn.example.com/pod/ep2.mp3", "audio"),
    M.makeItem("https://cdn.example.com/pod/ep3.mp3", "audio")
  ]);
  assert.equal(items.length, 3, "no stream manifest → numbered files are content, not chunks");
});

test("keeps a plain digit-ending download in an UNRELATED folder even when a stream is present", () => {
  // A movie site: an HLS trailer stream under /feature/, plus a real, separately downloadable file
  // under /promos/ whose name merely ends in a digit (no codec/bitrate/resolution marker). It must be
  // spared — the weak digit-suffix heuristic only applies beside a manifest, not page-wide.
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/feature/master.m3u8", "stream"),
    M.makeItem("https://cdn.example.com/promos/big-buck-bunny-2024.mp4", "video")
  ]);
  assert.equal(items.length, 2, "the unrelated .mp4 must survive");
  assert.ok(items.some((i) => i.url.endsWith("big-buck-bunny-2024.mp4")));
});

test("drops adaptive segments even on a DIFFERENT host/folder than the manifest (DASH-IF case)", () => {
  // A manifest on one CDN with its media segments on another (dash.akamaized vs dash.edgesuite). The
  // segments carry strong markers (codec h264, bitrate) so they're dropped regardless of folder.
  const items = M.dedupeAndRank([
    M.makeItem("https://dash.akamaized.net/dash264/TestCases/1a/netflix/exMPD_BIP_TC1.mpd", "stream"),
    M.makeItem("http://dash.edgesuite.net/dash264/TestCases/1a/netflix/ElephantsDream_H264BPL30_0100.264.dash", "video"),
    M.makeItem("http://dash.edgesuite.net/dash264/TestCases/1a/netflix/ElephantsDream_AAC48K_064.mp4.dash", "audio")
  ]);
  assert.deepEqual(items.map((i) => i.type), ["stream"], "strong-signal segments must be dropped anywhere");
});

test("drops a bare digit-suffix media file sitting in the manifest's OWN folder", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/d/master.m3u8", "stream"),
    M.makeItem("https://cdn.example.com/d/clip_7.mp4", "video")   // same folder + bare digit suffix
  ]);
  assert.deepEqual(items.map((i) => i.type), ["stream"]);
});

test("keeps two unrelated streams in non-nested folders", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/videoA/master.m3u8", "stream"),
    M.makeItem("https://cdn.example.com/videoB/master.m3u8", "stream")
  ]);
  assert.equal(items.length, 2);
});

test("collapses same-folder variant playlists to their master (Unified Streaming .ism)", () => {
  const b = "https://demo.unified-streaming.com/video/tears-of-steel/tears-of-steel.ism";
  const items = M.dedupeAndRank([
    M.makeItem(`${b}/.m3u8`, "stream"),                                          // master, empty stem
    M.makeItem(`${b}/tears-of-steel-audio_eng=64008-video_eng=401000.m3u8`, "stream"),
    M.makeItem(`${b}/tears-of-steel-audio_eng=128002-video_eng=1501000.m3u8`, "stream"),
    M.makeItem(`${b}/tears-of-steel-audio_eng=128002-video_eng=1001000.m3u8`, "stream")
  ]);
  assert.equal(items.length, 1);
  assert.ok(items[0].url.endsWith("/.m3u8"));
});

test("collapses master + same-folder alt-audio rendition playlist to the master", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/d/master.m3u8", "stream"),
    M.makeItem("https://cdn.example.com/d/audio_eng.m3u8", "stream")
  ]);
  assert.equal(items.length, 1);
  assert.ok(items[0].url.endsWith("/master.m3u8"));
});

test("does NOT collapse two master-named streams in the same folder (two videos)", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://cdn.example.com/d/movie1.m3u8", "stream"),
    M.makeItem("https://cdn.example.com/d/movie2.m3u8", "stream")
  ]);
  assert.equal(items.length, 2);
});

test("collapses same-folder variants to a markedly-shorter master name (Shaka hls.m3u8)", () => {
  const b = "https://storage.googleapis.com/shaka-demo-assets/angel-one-hls";
  const items = M.dedupeAndRank([
    M.makeItem(`${b}/hls.m3u8`, "stream"),                                  // master, short stem
    M.makeItem(`${b}/playlist_v-0360p-0750k-libx264.mp4.m3u8`, "stream"),
    M.makeItem(`${b}/playlist_a-eng-0128k-aac-2c.mp4.m3u8`, "stream"),
    M.makeItem(`${b}/playlist_s-en.webvtt.m3u8`, "stream"),
    M.makeItem(`${b}/v-0360p-0750k-libx264-init.mp4`, "video"),            // init segments
    M.makeItem(`${b}/a-eng-0128k-aac-2c-init.mp4`, "video")
  ]);
  assert.equal(items.length, 1);
  assert.ok(items[0].url.endsWith("/hls.m3u8"));
});

test("drops unnumbered DASH track files under a manifest folder (audio/subtitle)", () => {
  const b = "https://storage.googleapis.com/shaka-demo-assets/angel-one";
  const items = M.dedupeAndRank([
    M.makeItem(`${b}/dash.mpd`, "stream"),
    M.makeItem(`${b}/audio_en_2c_64k_opus.webm`, "audio"),
    M.makeItem(`${b}/text_el.mp4`, "video")
  ]);
  assert.deepEqual(items.map((i) => i.type), ["stream"]);
});

test("drops init.mp4 segments in numbered subfolders under a manifest", () => {
  const b = "https://media.axprod.net/TestVectors/v7-Clear";
  const items = M.dedupeAndRank([
    M.makeItem(`${b}/Manifest_1080p.mpd`, "stream"),
    M.makeItem(`${b}/2/init.mp4`, "video"),
    M.makeItem(`${b}/15/init.mp4`, "video"),
    M.makeItem(`${b}/1/init.mp4`, "audio")
  ]);
  assert.equal(items.length, 1);
  assert.ok(items[0].url.endsWith(".mpd"));
});

test("keeps two distinct videos on one page (multi-video, no collapse)", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://a-cdn.example.com/showA/master.m3u8", "stream"),
    M.makeItem("https://b-cdn.example.com/showB/master.m3u8", "stream")
  ]);
  assert.equal(items.length, 2);
});

test("dedupes the same distinctive file mirrored across hosts (origin 302 → CDN node)", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://archive.org/serve/BBB/big_buck_bunny_720p_surround.mp4", "video"),
    M.makeItem("https://dn80.us.archive.org/0/items/BBB/big_buck_bunny_720p_surround.mp4?cnt=0", "video")
  ]);
  assert.equal(items.length, 1);
});

test("does NOT dedupe generic same-named files across hosts (two unrelated video.mp4)", () => {
  const items = M.dedupeAndRank([
    M.makeItem("https://a.example.com/video.mp4", "video"),
    M.makeItem("https://b.example.com/video.mp4", "video")
  ]);
  assert.equal(items.length, 2);
});

test("filters CMAF chunk extensions as segments", () => {
  assert.equal(M.classifyByURL("https://cdn.example.com/s/seg_5.cmfv"), null);
  assert.equal(M.classifyByURL("https://cdn.example.com/s/seg_5.cmfa"), null);
});

test("videoKey is null for URLs without rendition structure", () => {
  assert.equal(M.videoKey("https://cdn.example.com/movie.mp4"), null);
  assert.equal(M.videoKey("https://cdn.example.com/a/b/song.mp3"), null);
  assert.ok(M.videoKey("https://cdn.example.com/v/vid/720x1280/x.mp4"));
});

test("helpers: hostOf / extensionOf / fileNameFromURL / audioExt", () => {
  assert.equal(M.hostOf("https://a.b.com/x/y.mp4?q=1"), "a.b.com");
  assert.equal(M.extensionOf("https://a.com/x/y.MP4"), "mp4");
  assert.equal(M.fileNameFromURL("https://a.com/x/My%20Clip.mp4"), "My Clip.mp4");
  assert.ok(M.audioExt("opus"));
  assert.ok(!M.audioExt("mp4"));
});

test("primaryPlayerIndex picks the largest video", () => {
  assert.equal(M.primaryPlayerIndex([
    { video: true, area: 200 * 120 },
    { video: true, area: 1280 * 720 },
    { video: true, area: 300 * 200 }
  ]), 1);
});

test("primaryPlayerIndex: a video always outranks a larger audio", () => {
  assert.equal(M.primaryPlayerIndex([
    { video: false, area: 5000 * 5000 },   // huge audio element
    { video: true, area: 180 * 120 }       // small video still wins
  ]), 1);
});

test("primaryPlayerIndex falls back to the largest audio when there is no video", () => {
  assert.equal(M.primaryPlayerIndex([
    { video: false, area: 100 },
    { video: false, area: 900 },
    { video: false, area: 400 }
  ]), 1);
});

test("primaryPlayerIndex returns -1 for an empty list and 0 for ties", () => {
  assert.equal(M.primaryPlayerIndex([]), -1);
  assert.equal(M.primaryPlayerIndex([{ video: true, area: 100 }, { video: true, area: 100 }]), 0);
});

// The reported bug: a YouTube watch page carries the main player plus smaller hover-preview and
// miniplayer <video>s. Only the main (largest) player should anchor the page-extraction pill.
test("primaryPlayerIndex: YouTube main player wins over preview/miniplayer videos", () => {
  const players = [
    { video: true, area: 854 * 480 },   // main player
    { video: true, area: 168 * 94 },    // sidebar hover preview
    { video: true, area: 168 * 94 },    // another preview
    { video: true, area: 400 * 225 }    // miniplayer
  ];
  assert.equal(M.primaryPlayerIndex(players), 0);
});
