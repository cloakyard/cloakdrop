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
  const SEGMENT_EXT = ["ts", "m4s", "cmfv", "cmfa", "cmft", "cmfm"];
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

  // ── Rendition collapsing ────────────────────────────────────────────────────────────────────
  // A single video is served as many URLs: a master playlist, one variant playlist per quality,
  // and several progressive files (per resolution/codec). Surfacing them all is the "wall of
  // streams" bug. We collapse every rendition of ONE video to a single representative by keying on
  // the video's directory with the *rendition* path segments (container role / codec / resolution)
  // stripped out — so all qualities of a video share a key, while genuinely different files never
  // merge (a URL with no rendition markers keys as null and passes through untouched).
  //
  // Path segments that denote a rendition's role, not the video's identity.
  const RENDITION_SEG = new Set([
    "pl", "vid", "hls", "dash", "manifest", "playlist", "chunklist",   // container / playlist role
    "avc1", "avc", "h264", "h265", "hevc", "hvc1", "av01", "vp9", "vp09", "mp4a", "aac", "opus", // codec
    "sd", "hd", "fhd", "uhd", "hi", "mid", "low", "hq", "lq"           // named qualities
  ]);
  const RES_SEG = /^\d{2,5}x\d{2,5}$/;   // 720x1280
  const HEIGHT_SEG = /^\d{3,4}p$/;        // 720p
  function isRenditionSeg(s) { return RENDITION_SEG.has(s) || RES_SEG.test(s) || HEIGHT_SEG.test(s); }

  function pathSegments(url) {
    try { return new URL(url).pathname.toLowerCase().split("/").filter(Boolean); }
    catch (_) { return []; }
  }

  // A grouping key that unites all rendition variants of one video, or `null` when the URL carries
  // no rendition structure (so distinct files/standalone media are never collapsed together).
  function videoKey(url) {
    const segs = pathSegments(url);
    if (segs.length === 0) return null;
    const dirs = segs.slice(0, -1);                       // drop the (per-rendition) filename
    if (!dirs.some(isRenditionSeg)) return null;          // no variant structure → keep as its own item
    const stable = dirs.filter((s) => !isRenditionSeg(s));
    return hostOf(url) + "/" + stable.join("/");
  }

  function resolutionArea(url) {
    const m = String(url).match(/(\d{2,5})x(\d{2,5})/);
    return m ? Number(m[1]) * Number(m[2]) : 0;
  }

  // Pick the one item to show for a group of renditions: prefer a stream (the app expands it into a
  // quality picker, covering every rendition at once); among streams prefer the master (shallowest
  // path — a master playlist sits above its per-quality variants). With no stream, prefer the
  // highest-resolution progressive file.
  function pickRepresentative(group) {
    const streams = group.filter((i) => i.type === "stream");
    const pool = streams.length ? streams : group;
    return pool.slice().sort((a, b) =>
      pathSegments(a.url).length - pathSegments(b.url).length ||
      resolutionArea(b.url) - resolutionArea(a.url)
    )[0];
  }

  // Collapse rendition variants to one representative per video; pass non-rendition items through.
  function collapseRenditions(items) {
    const groups = new Map();
    const out = [];
    for (const item of items) {
      const key = item && item.url ? videoKey(item.url) : null;
      if (key == null) { if (item) out.push(item); continue; }
      const existing = groups.get(key);
      if (existing) { existing.push(item); }
      else { const g = [item]; groups.set(key, g); out.push(g); }   // reserve position at first sight
    }
    // Replace each reserved group slot with its chosen representative.
    return out.map((slot) => (Array.isArray(slot) ? pickRepresentative(slot) : slot));
  }

  // ── Stream playlist + segment collapsing ────────────────────────────────────────────────────
  // A single adaptive video also shows up as (a) several sub-playlists — one HLS variant `.m3u8`
  // per quality, plus audio/subtitle renditions — that live in sibling sub-folders of the master,
  // and (b) hundreds of media *segments* (`.m4v`/`.m4a`/`.aac`/… numbered chunks) that carry a
  // normal media extension but are useless individually. Neither is caught by resolution/codec
  // rendition-keying, so they need their own passes.

  function dirKey(url) {
    const segs = pathSegments(url);
    segs.pop();                                   // drop filename
    return hostOf(url) + "/" + segs.join("/");
  }

  // Filename stems that mark a *master* multivariant playlist rather than a per-quality variant —
  // includes the empty stem (Unified Streaming serves the master as `<asset>.ism/.m3u8`).
  const MASTER_STEM = new Set(["", "master", "index", "main", "manifest", "playlist", "all", "stream", "video"]);
  function stemOf(url) { return fileNameFromURL(url).replace(/\.[^.]+$/, "").toLowerCase(); }

  // Keep only the *master* playlist of each stream. A stream is a per-quality variant (drop it) when
  // either (1) its folder is a strict descendant of another stream's folder (Apple/Mux/Bitmovin put
  // variants in sub-folders), or (2) it sits in the SAME folder as a master-named playlist (Unified
  // Streaming lists `.m3u8` + `<asset>-audio=…-video=….m3u8` siblings). Two unrelated masters — in
  // non-nested folders, or same-folder but neither master-named — both survive.
  function collapseStreamPlaylists(items) {
    const streams = items.filter((i) => i.type === "stream");
    if (streams.length < 2) return items;
    const meta = streams.map((s) => ({ s, dir: dirKey(s.url), depth: pathSegments(s.url).length, stem: stemOf(s.url) }));
    const keep = new Set(streams);
    // (1) descendant folders → variants of the shallower master.
    for (const a of meta) {
      for (const b of meta) {
        if (a.s === b.s) continue;
        if (b.depth < a.depth && a.dir.startsWith(b.dir + "/")) { keep.delete(a.s); break; }
      }
    }
    // (2) same folder + a master-named sibling → the non-master-named ones are its variants.
    const byDir = new Map();
    for (const m of meta) if (keep.has(m.s)) { (byDir.get(m.dir) || byDir.set(m.dir, []).get(m.dir)).push(m); }
    for (const group of byDir.values()) {
      if (group.length < 2) continue;
      const masters = group.filter((m) => MASTER_STEM.has(m.stem));
      if (masters.length > 0 && masters.length < group.length) {
        for (const m of group) if (!MASTER_STEM.has(m.stem)) keep.delete(m.s);
      }
    }
    return items.filter((i) => i.type !== "stream" || keep.has(i));
  }

  // A media file whose name stem ends in an index number — `..._0`, `fileSequence12`, `chunk-5`,
  // `seg9`. The digits may be glued straight to letters (HLS `fileSequenceN`) so we match any
  // trailing digit; this only fires when a stream manifest is present (see `dropStreamSegments`).
  const SEGMENT_INDEX = /\d$/;

  // When the page also served a stream manifest, bare media files that look like numbered chunks are
  // that stream's segments (DASH `.m4v`/`.m4a`, HLS `.aac`/`.mp4` pieces) — never a standalone grab.
  // Gated on a manifest being present so numbered *content* (podcast ep3.mp3, trailer2.mp4) on a
  // manifest-free page is left alone.
  function dropStreamSegments(items) {
    if (!items.some((i) => i.type === "stream")) return items;
    return items.filter((i) => {
      if (i.type !== "video" && i.type !== "audio") return true;
      const stem = fileNameFromURL(i.url).replace(/\.[^.]+$/, "");
      return !SEGMENT_INDEX.test(stem);
    });
  }

  // Drop duplicate URLs, collapse rendition variants → variant playlists → stream segments, then
  // order streams → video → audio → file (stable within a rank).
  function dedupeAndRank(items) {
    const seen = new Set();
    const unique = [];
    for (const item of items) {
      if (!item || !item.url || seen.has(item.url)) continue;
      seen.add(item.url);
      unique.push(item);
    }
    let out = collapseRenditions(unique);
    out = collapseStreamPlaylists(out);
    out = dropStreamSegments(out);
    out.sort((a, b) => (TYPE_RANK[a.type] ?? 9) - (TYPE_RANK[b.type] ?? 9));
    return out;
  }

  const API = {
    STREAM_EXT, MEDIA_EXT, FILE_EXT, SEGMENT_EXT, AUDIO_EXT, TYPE_RANK, TYPE_LABEL,
    hostOf, extensionOf, audioExt, fileNameFromURL,
    isNoise, makeItem, classifyByURL, classifyByContentType,
    videoKey, collapseRenditions, collapseStreamPlaylists, dropStreamSegments, dedupeAndRank
  };

  if (typeof module !== "undefined" && module.exports) module.exports = API;
  if (typeof self !== "undefined") self.CloakDropMedia = API;
  if (typeof globalThis !== "undefined") globalThis.CloakDropMedia = API;
})();
