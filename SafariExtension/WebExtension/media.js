// CloakDrop shared media core — the single, dependency-free classifier/filter used by the
// background service worker, the in-page content script, the toolbar popup, AND the Node test
// harness. It has NO DOM and NO extension-API access, so the same logic runs identically in a
// browser and under `node --test`.
//
// Dual-export: browsers pick it up as `self.CloakDropMedia` (SW `importScripts`, popup <script>,
// content_scripts array, Firefox background.scripts); Node picks it up as `module.exports`.

(function () {
  "use strict";

  // Streaming manifests the app resolves into a quality picker; self-contained media files; and
  // plain downloadable files. Segment extensions are the chunks of an adaptive stream — never
  // surfaced individually (the manifest is what we want).
  const STREAM_EXT = ["m3u8", "m3u", "mpd"];
  const MEDIA_EXT = [
    "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "3gp", "ogv",
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"
  ];
  const FILE_EXT = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "iso",
    "exe", "msi", "apk", "deb", "rpm", "pdf", "epub"];
  const SEGMENT_EXT = ["ts", "m4s"];
  const AUDIO_EXT = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"];

  // List ordering: streams (the prize on video sites) first, then video, audio, files.
  const TYPE_RANK = { stream: 0, video: 1, audio: 2, file: 3 };
  const TYPE_LABEL = { stream: "STREAM", video: "VIDEO", audio: "AUDIO", file: "FILE" };

  // URL substrings that mark analytics / telemetry / ad pings — never downloadable media.
  const BEACON_HINTS = [
    "generate_204", "gen_204", "/qoe", "/ptracking", "/atr?", "/atr/", "/api/stats", "/log_event",
    "/csi?", "/pagead/", "doubleclick.net", "google-analytics.com", "scorecardresearch",
    "/beacon", "/collect?", "/measurement", "/interaction?"
  ];
  // Generic UI / notification sound basenames (site-agnostic). These short, generically-named audio
  // clips are overwhelmingly interface sounds, not content — this is what kills YouTube's
  // open.mp3 / success.mp3 / failure.mp3 / no_input.mp3 junk without any YouTube-specific rule.
  const UI_SOUND_NAMES = [
    "open", "close", "success", "failure", "error", "click", "no_input", "notification",
    "ding", "beep", "pop", "tap", "select", "hover", "start", "stop", "mute", "unmute",
    "alert", "chime", "ping", "tick", "swipe", "toggle"
  ];
  // Media smaller than this is a ping / sound effect, not a real download.
  const MIN_MEDIA_BYTES = 1024;

  function hostOf(url) { try { return new URL(url).host; } catch (_) { return ""; } }

  function extensionOf(url) {
    try {
      const path = new URL(url).pathname;
      const last = path.split("/").pop() || "";
      const dot = last.lastIndexOf(".");
      return dot >= 0 ? last.slice(dot + 1).toLowerCase() : "";
    } catch (_) { return ""; }
  }

  function audioExt(ext) { return AUDIO_EXT.includes(ext); }

  function fileNameFromURL(url) {
    try { return decodeURIComponent(new URL(url).pathname.split("/").filter(Boolean).pop() || ""); }
    catch (_) { return ""; }
  }

  // True when a URL/response is noise we must never surface as downloadable media. `opts` may carry
  // `contentType` and `contentLength` learned from response headers.
  function isNoise(url, opts) {
    opts = opts || {};
    const lower = String(url).toLowerCase();
    const host = hostOf(url).toLowerCase();
    // Raw adaptive chunk hosts — split, signed, per-range; useless as bare URLs. YouTube's
    // googlevideo traffic is handled by the dedicated YouTube path, not the generic list.
    if (host.endsWith("googlevideo.com")) return true;
    if (BEACON_HINTS.some((h) => lower.includes(h))) return true;
    const ext = extensionOf(url);
    if (SEGMENT_EXT.includes(ext)) return true;
    // Interface sound effects: a short, generically-named audio clip.
    const base = fileNameFromURL(url).replace(/\.[^.]+$/, "").toLowerCase();
    if (audioExt(ext) && UI_SOUND_NAMES.includes(base)) return true;
    // Sub-1 KB "media" is a ping/sound, not content.
    const len = opts.contentLength;
    if (len != null && Number(len) > 0 && Number(len) < MIN_MEDIA_BYTES) return true;
    return false;
  }

  // Build a media item. `extra` may add container/quality/height/audioUrl/filename/source.
  function makeItem(url, type, extra) {
    const item = { url, type, label: fileNameFromURL(url) || url, source: "wire" };
    return Object.assign(item, extra || {});
  }

  // A media item derived from a URL alone, or null if the URL isn't recognisably media.
  function classifyByURL(url) {
    if (isNoise(url, {})) return null;
    const ext = extensionOf(url);
    if (!ext) return null;
    if (STREAM_EXT.includes(ext)) return makeItem(url, "stream");
    if (MEDIA_EXT.includes(ext)) return makeItem(url, audioExt(ext) ? "audio" : "video");
    return null;
  }

  // A media item derived from a response's content-type, for URLs without a telltale extension.
  function classifyByContentType(url, contentType, contentLength) {
    if (!contentType) return null;
    if (isNoise(url, { contentType, contentLength })) return null;
    const type = contentType.split(";")[0].trim().toLowerCase();
    if (type === "application/vnd.apple.mpegurl" || type === "application/x-mpegurl" ||
        type === "application/dash+xml") {
      return makeItem(url, "stream");
    }
    if (type.startsWith("video/")) return makeItem(url, "video");
    if (type.startsWith("audio/")) return makeItem(url, "audio");
    return null;
  }

  // Drop duplicate URLs and order streams → video → audio → file (stable within a rank).
  function dedupeAndRank(items) {
    const seen = new Set();
    const out = [];
    for (const item of items) {
      if (!item || !item.url || seen.has(item.url)) continue;
      seen.add(item.url);
      out.push(item);
    }
    out.sort((a, b) => (TYPE_RANK[a.type] ?? 9) - (TYPE_RANK[b.type] ?? 9));
    return out;
  }

  const API = {
    STREAM_EXT, MEDIA_EXT, FILE_EXT, SEGMENT_EXT, AUDIO_EXT, TYPE_RANK, TYPE_LABEL,
    hostOf, extensionOf, audioExt, fileNameFromURL,
    isNoise, makeItem, classifyByURL, classifyByContentType, dedupeAndRank
  };

  if (typeof module !== "undefined" && module.exports) module.exports = API;
  if (typeof self !== "undefined") self.CloakDropMedia = API;
  if (typeof globalThis !== "undefined") globalThis.CloakDropMedia = API;
})();
