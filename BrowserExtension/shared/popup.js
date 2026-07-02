// CloakDrop toolbar popup — lists downloadable media on the current tab and sends any of it to the
// app. Two sources are merged: what's already in the page's DOM (scanned on demand, only when you
// open this popup) and what the background script saw stream past on the network (HLS/DASH manifests
// and media responses the DOM never exposes). Nothing is collected until you open the popup, and a
// download only leaves the browser when you click it.

const api = globalThis.browser ?? globalThis.chrome;

// Type ordering for the list: streams (the prize on video sites) first, then plain media, then files.
const TYPE_RANK = { stream: 0, video: 1, audio: 2, file: 3 };
const TYPE_LABEL = { stream: "STREAM", video: "VIDEO", audio: "AUDIO", file: "FILE" };

init();

async function init() {
  const tab = await activeTab();
  if (!tab || tab.id == null) { showEmpty(); return; }

  const [youtube, sniffed, dom] = await Promise.all([
    youTubeFormats(tab.id, tab.url || ""),
    sniffedMedia(tab.id),
    scanPageDOM(tab.id)
  ]);
  // YouTube's own format list (real resolutions, with audio) leads; everything else follows, ordered
  // streams → video → audio → file.
  const rest = dedupe([...sniffed, ...dom]).sort((a, b) => (TYPE_RANK[a.type] ?? 9) - (TYPE_RANK[b.type] ?? 9));
  const items = dedupe([...youtube, ...rest]);

  if (!items.length) { showEmpty(); return; }
  render(items, tab.url || "");
}

// YouTube serves adaptive audio/video from googlevideo with no manifest, so the network sniffer can't
// reconstruct resolutions. Instead read the page's own player data (in the page's JS world): the
// *progressive* formats (muxed, one playable file, ≤720p) plus the higher-resolution *adaptive*
// formats — each video-only rendition paired with the best audio track, which the app downloads
// alongside and muxes in, so every offered resolution has sound. Ciphered (signatureCipher) URLs need
// JS descrambling we don't do, so they're skipped.
async function youTubeFormats(tabId, tabUrl) {
  if (!/(^|\.)youtube\.com$|(^|\.)youtu\.be$/.test(hostOf(tabUrl))) return [];
  try {
    const results = await api.scripting.executeScript({ target: { tabId }, world: "MAIN", func: extractYouTube });
    return (results && results[0] && results[0].result) || [];
  } catch (_) { return []; }   // MAIN world unsupported, or player data absent
}

// Runs in the page's own JS context (world: MAIN) so it can read `ytInitialPlayerResponse`.
function extractYouTube() {
  try {
    const player = window.ytInitialPlayerResponse;
    const streaming = player && player.streamingData;
    if (!streaming) return [];
    const details = player.videoDetails || {};
    const title = ((details.title || "video")
      .replace(/[\/\\:*?"<>|\n\r\t]+/g, "_").replace(/\s+/g, " ").trim().slice(0, 120)) || "video";

    const isVideo = (f) => (f.mimeType || "").indexOf("video/") === 0;
    const extOf = (f) => ((f.mimeType || "").indexOf("webm") >= 0 ? "webm" : "mp4");
    const resOf = (f) => f.qualityLabel || (f.height ? f.height + "p" : "video");

    // The best audio-only adaptive track (highest bitrate, direct url) to pair with video-only renditions.
    const adaptive = streaming.adaptiveFormats || [];
    const bestAudio = adaptive
      .filter((f) => f.url && (f.mimeType || "").indexOf("audio/") === 0)
      .sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0))[0];

    // Gather candidates from both sources, skipping ciphered entries (no direct `url`).
    const candidates = [];
    for (const f of (streaming.formats || [])) {          // progressive: already muxed, ≤720p
      if (f.url && isVideo(f)) {
        candidates.push({ url: f.url, height: f.height || 0, ext: extOf(f), res: resOf(f), muxed: true });
      }
    }
    if (bestAudio) {
      for (const f of adaptive) {                         // adaptive video-only: pair with the audio track
        if (f.url && isVideo(f)) {
          candidates.push({ url: f.url, audioUrl: bestAudio.url, height: f.height || 0, ext: extOf(f), res: resOf(f), muxed: false });
        }
      }
    }

    // One entry per resolution, preferring: progressive (no mux needed) > H.264/mp4 (muxed in-process
    // by AVFoundation) > VP9/AV1 webm (needs the bundled ffmpeg) — the rendition that assembles most
    // cheaply, keeping the list short.
    const rank = (c) => (c.muxed ? 3 : (c.ext === "mp4" ? 2 : 1));
    const byHeight = new Map();
    for (const c of candidates) {
      const current = byHeight.get(c.height);
      if (!current || rank(c) > rank(current)) byHeight.set(c.height, c);
    }

    return [...byHeight.values()]
      .sort((a, b) => b.height - a.height)
      .map((c) => ({
        url: c.url,
        audioUrl: c.audioUrl,                             // undefined for progressive (already has audio)
        type: "video",
        label: c.res + " · " + c.ext + (c.muxed ? " (with audio)" : ""),
        quality: c.height,
        filename: title + "." + c.ext
      }));
  } catch (_) { return []; }
}

async function activeTab() {
  try {
    const tabs = await api.tabs.query({ active: true, currentWindow: true });
    return tabs && tabs[0];
  } catch (_) { return null; }
}

// The background script's per-tab list of media seen on the wire.
async function sniffedMedia(tabId) {
  try {
    const response = await api.runtime.sendMessage({ action: "getMedia", tabId });
    return (response && response.items) || [];
  } catch (_) { return []; }
}

// Scan the live page for media, injecting the scanner on demand (nothing runs on the page until now).
async function scanPageDOM(tabId) {
  try {
    const results = await api.scripting.executeScript({ target: { tabId }, func: pageScan });
    return (results && results[0] && results[0].result) || [];
  } catch (_) { return []; }   // restricted page (e.g. the store, PDF viewer) — network hits still show
}

// Runs in the page's context (serialized by executeScript), so it's fully self-contained.
function pageScan() {
  const STREAM = ["m3u8", "m3u", "mpd"];
  const MEDIA = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "3gp", "ogv",
    "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"];
  const FILE = ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg", "iso", "exe", "msi",
    "apk", "deb", "rpm", "pdf", "epub"];
  const AUDIO = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"];

  const seen = new Set();
  const out = [];
  const absolute = (u) => { try { return new URL(u, location.href).href; } catch (_) { return ""; } };
  const extOf = (u) => {
    const path = (() => { try { return new URL(u, location.href).pathname; } catch (_) { return ""; } })();
    const last = path.split("/").pop() || "";
    const dot = last.lastIndexOf(".");
    return dot >= 0 ? last.slice(dot + 1).toLowerCase() : "";
  };
  const nameOf = (u) => {
    try { return decodeURIComponent(new URL(u, location.href).pathname.split("/").filter(Boolean).pop() || "") || u; }
    catch (_) { return u; }
  };
  const push = (raw, type) => {
    const url = absolute(raw);
    if (!url || !url.startsWith("http")) return;   // skip blob:/data:/mediasource: — not directly fetchable
    if (seen.has(url)) return;
    seen.add(url);
    out.push({ url, type, label: nameOf(url) });
  };

  document.querySelectorAll("video, audio").forEach((el) => {
    const type = el.tagName.toLowerCase() === "audio" ? "audio" : "video";
    if (el.currentSrc || el.src) push(el.currentSrc || el.src, type);
    el.querySelectorAll("source").forEach((s) => { if (s.src) push(s.src, type); });
  });
  document.querySelectorAll("a[href]").forEach((a) => {
    const ext = extOf(a.href);
    if (STREAM.includes(ext)) push(a.href, "stream");
    else if (MEDIA.includes(ext)) push(a.href, AUDIO.includes(ext) ? "audio" : "video");
    else if (FILE.includes(ext)) push(a.href, "file");
  });
  return out;
}

function dedupe(items) {
  const seen = new Set();
  const out = [];
  for (const item of items) {
    if (!item || !item.url || seen.has(item.url)) continue;
    seen.add(item.url);
    out.push(item);
  }
  return out;
}

function render(items, referrer) {
  const list = document.getElementById("list");
  document.getElementById("empty").hidden = true;
  document.getElementById("count").textContent = String(items.length);
  document.getElementById("summary").hidden = false;

  for (const item of items) {
    const row = document.createElement("div");
    row.className = "row";

    const chip = document.createElement("span");
    chip.className = "chip " + item.type;
    chip.textContent = TYPE_LABEL[item.type] || "FILE";

    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = item.label || item.url;
    name.title = item.url;
    const host = document.createElement("div");
    host.className = "host";
    host.textContent = hostOf(item.url);
    meta.append(name, host);

    const button = document.createElement("button");
    button.className = "download";
    button.textContent = "Download";
    button.addEventListener("click", () => sendDownload(item, referrer, button));

    row.append(chip, meta, button);
    list.appendChild(row);
  }
}

async function sendDownload(item, referrer, button) {
  button.disabled = true;
  button.textContent = "Sent";
  button.classList.add("sent");
  try {
    await api.runtime.sendMessage({ action: "download", url: item.url, audioUrl: item.audioUrl, referrer, filename: item.filename });
  } catch (_) {
    button.textContent = "Retry";
    button.classList.remove("sent");
    button.disabled = false;
  }
}

function hostOf(url) {
  try { return new URL(url).host; } catch (_) { return ""; }
}

function showEmpty() {
  document.getElementById("empty").hidden = false;
  document.getElementById("summary").hidden = true;
}
