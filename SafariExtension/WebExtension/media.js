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
    // (2) same folder → identify the master and drop its variants.
    const byDir = new Map();
    for (const m of meta) if (keep.has(m.s)) { (byDir.get(m.dir) || byDir.set(m.dir, []).get(m.dir)).push(m); }
    for (const group of byDir.values()) {
      if (group.length < 2) continue;
      const masters = group.filter((m) => MASTER_STEM.has(m.stem));
      if (masters.length > 0 && masters.length < group.length) {
        // A master-named sibling is present → the others are its variants.
        for (const m of group) if (!MASTER_STEM.has(m.stem)) keep.delete(m.s);
        continue;
      }
      if (masters.length === 0) {
        // No master name: a uniquely, markedly shorter stem is the un-decorated master beside its
        // quality-encoding variants (Shaka `hls.m3u8` next to `playlist_v-0360p-…m3u8`). Require a
        // big margin so two similarly-named videos ("movie1"/"movie2") are never collapsed.
        const lens = group.map((m) => m.stem.length).sort((a, b) => a - b);
        const min = lens[0], second = lens[1] ?? Infinity;
        const shortest = group.filter((m) => m.stem.length === min);
        if (shortest.length === 1 && (min * 3 <= second || second - min >= 10)) {
          for (const m of group) if (m.stem.length !== min) keep.delete(m.s);
        }
      }
    }
    return items.filter((i) => i.type !== "stream" || keep.has(i));
  }

  // Does a media filename look like a stream part (segment / per-track init / rendition) rather than
  // a standalone file? Matches a segment index, init/seg/frag/chunk markers, a resolution/bitrate or
  // codec tag, or a track-role prefix (Shaka `audio_en…`, `text_el`, `v-0360p`, `a-eng`, `s-en`).
  // STRONG signals that a media URL is an adaptive-stream part rather than a standalone download: an
  // explicit segment/init/chunk word, a resolution/bitrate/codec tag, or a track-role prefix. These
  // are specific enough to trust ANYWHERE on the page (a stream's media often lives on a different
  // CDN host/path than its manifest — e.g. DASH-IF's segments on dash.edgesuite.net).
  function looksLikeStreamSegment(url) {
    const name = fileNameFromURL(url).toLowerCase();
    const stem = name.replace(/\.[^.]+$/, "");
    // A double media extension (foo.mp4.dash, seg.264.dash, x.ts.enc): the inner extension means the
    // "file" is a wrapped stream segment, never a standalone download.
    if (/\.(mp4|m4v|m4a|m4s|ts|264|265|h264|h265|aac|webm|ismv|isma|dash|mpd|m3u8)\.[a-z0-9]{1,6}$/.test(name)) return true;
    return /(^|[_\-.])(init|seg|segment|frag|fragment|chunk)([_\-.]|\d|$)/.test(stem)
      || /\d+x\d+|\b\d{3,4}p\b|\b\d{2,5}k\b/.test(stem)
      || /(avc1?|hevc|hvc1|h26[45]|vp0?9|av01|opus|mp4a)/.test(stem)
      || /^(audio|video|text|subtitle|sub|cc)[_\-]/.test(stem)
      || /(^|[_\-])[avs]-[a-z0-9]/.test(stem);
  }
  // The strong signals PLUS the WEAK "name just ends in a digit" heuristic. On its own the weak part
  // can't tell a segment (fileSequence7) from a real download (movie-2024), so callers apply it only
  // to files sitting in a manifest's own folder — never to spare an unrelated digit-ending download.
  function looksLikeStreamPart(url) {
    const stem = fileNameFromURL(url).replace(/\.[^.]+$/, "").toLowerCase();
    return /\d$/.test(stem) || looksLikeStreamSegment(url);
  }

  // When the page served a stream manifest, its bare media files (segments, per-track init/media,
  // subtitle tracks) are never a standalone grab — the manifest is. Drop a video/audio item that is
  // (a) in a strict SUB-folder of a manifest (segments live under the master), or (b) in the SAME
  // folder as a manifest *and* looks like a stream part (so a plain sibling download is spared). All
  // gated on a manifest being present, so ordinary numbered content (podcast ep3.mp3) is kept.
  function dropStreamMedia(items) {
    const manifestDirs = items.filter((i) => i.type === "stream").map((i) => dirKey(i.url));
    if (manifestDirs.length === 0) return items;
    const inSubfolder = (url) => { const d = dirKey(url); return manifestDirs.some((md) => d.startsWith(md + "/")); };
    const inManifestFolder = (url) => manifestDirs.includes(dirKey(url));
    return items.filter((i) => {
      if (i.type !== "video" && i.type !== "audio") return true;
      if (inSubfolder(i.url)) return false;                             // (a) a chunk under the master's tree
      if (looksLikeStreamSegment(i.url)) return false;                  // (b) a codec/bitrate/seg-named part, any host/folder
      return !(inManifestFolder(i.url) && looksLikeStreamPart(i.url));  // (c) a bare digit-suffix part BESIDE the master
      // A digit-ending file in an UNRELATED folder with no strong stream marker (movie-2024.mp4 next
      // to some other page's stream) is a real download and is spared — that's the same-folder gate.
    });
  }

  // Generic filenames that don't uniquely identify a file — never dedupe across hosts on these.
  const GENERIC_NAME = new Set(["video", "media", "index", "stream", "movie", "clip", "file",
    "output", "playlist", "master", "main", "default", "sample", "content", "player", "source"]);

  // Collapse the same progressive file served from more than one host — a 302 to a CDN node, or an
  // origin/mirror pair (archive.org `/serve/…` → `dnNNN.us.archive.org/…`). Keyed on an identical,
  // *distinctive* basename (long and non-generic) so two unrelated `video.mp4` embeds are never merged.
  function dedupeSameFile(items) {
    const seen = new Set();
    return items.filter((i) => {
      if (i.type !== "video" && i.type !== "audio") return true;
      const name = fileNameFromURL(i.url).toLowerCase();
      const stem = name.replace(/\.[^.]+$/, "");
      if (stem.length < 12 || GENERIC_NAME.has(stem)) return true;   // not distinctive → keep
      if (seen.has(name)) return false;
      seen.add(name);
      return true;
    });
  }

  // Drop duplicate URLs, collapse rendition variants → variant playlists → stream media → same-file
  // mirrors, then order streams → video → audio → file (stable within a rank).
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
    out = dropStreamMedia(out);
    out = dedupeSameFile(out);
    out.sort((a, b) => (TYPE_RANK[a.type] ?? 9) - (TYPE_RANK[b.type] ?? 9));
    return out;
  }

  // Pick the "primary" media player from per-element descriptors `{ video: bool, area: number }`:
  // the largest visible `<video>`, or — only when the page has none — the largest `<audio>`. The
  // page-global affordances (sniffed streams and the yt-dlp page-extraction fallback) attach to just
  // this one player, so an adaptive site like YouTube — whose watch page carries several `<video>`
  // elements (main player, hover-preview thumbnails, the miniplayer), each a blob/MediaSource that
  // resolves to the very same page URL — shows ONE download pill instead of a duplicate on each.
  // Returns -1 for an empty list. Pure and DOM-free so it's unit-tested directly.
  function primaryPlayerIndex(players) {
    let best = -1;
    let bestScore = -1;
    for (let i = 0; i < players.length; i++) {
      const p = players[i] || {};
      const score = (p.video ? 1e12 : 0) + (p.area > 0 ? p.area : 0);   // video always outranks audio
      if (score > bestScore) { bestScore = score; best = i; }
    }
    return best;
  }

  const API = {
    STREAM_EXT, MEDIA_EXT, FILE_EXT, SEGMENT_EXT, AUDIO_EXT, TYPE_RANK, TYPE_LABEL,
    hostOf, extensionOf, audioExt, fileNameFromURL,
    isNoise, makeItem, classifyByURL, classifyByContentType,
    videoKey, collapseRenditions, collapseStreamPlaylists, dropStreamMedia, dedupeAndRank,
    primaryPlayerIndex
  };

  if (typeof module !== "undefined" && module.exports) module.exports = API;
  if (typeof self !== "undefined") self.CloakDropMedia = API;
  if (typeof globalThis !== "undefined") globalThis.CloakDropMedia = API;
})();
