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

test("helpers: hostOf / extensionOf / fileNameFromURL / audioExt", () => {
  assert.equal(M.hostOf("https://a.b.com/x/y.mp4?q=1"), "a.b.com");
  assert.equal(M.extensionOf("https://a.com/x/y.MP4"), "mp4");
  assert.equal(M.fileNameFromURL("https://a.com/x/My%20Clip.mp4"), "My Clip.mp4");
  assert.ok(M.audioExt("opus"));
  assert.ok(!M.audioExt("mp4"));
});
