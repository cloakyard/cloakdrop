// CloakDrop toolbar popup — lists downloadable media on the current tab and sends any of it to the
// app. Sources merged: media already in the page's DOM (scanned on demand when you open this popup),
// what the background script saw stream past on the network (HLS/DASH manifests and media responses
// the DOM never exposes), and — for an adaptive player with no grabbable file (YouTube et al.) — a
// "Download this video" item that hands the page URL to the app, which resolves it with its bundled
// yt-dlp into real quality tiers. Nothing is collected until you open the popup, and a download only
// leaves the browser when you click it.

const api = globalThis.browser ?? globalThis.chrome;
// The shared media core (loaded by popup.html before this file) — same collapse/dedupe the in-page
// pill and the service worker use, so the popup can't show rendition variants or origin/mirror
// duplicates the other two surfaces already fold away.
const M = globalThis.CloakDropMedia;

// List ordering: a page-extraction item first, then streams, plain media, files.
const TYPE_RANK = { page: 0, stream: 1, video: 2, audio: 3, file: 4 };
const TYPE_LABEL = { page: "VIDEO", stream: "STREAM", video: "VIDEO", audio: "AUDIO", file: "FILE" };

init();

async function init() {
  const tab = await activeTab();
  if (!tab || tab.id == null) { showEmpty(); return; }

  const [sniffed, dom] = await Promise.all([
    sniffedMedia(tab.id),
    scanPageDOM(tab.id)
  ]);
  // Collapse rendition variants, variant→master playlists, stream segments, and origin/mirror pairs
  // across the MERGED set (the sniffed half is pre-collapsed by the worker; the DOM half is raw), then
  // order everything page → stream → video → audio → file. Falls back to plain URL-dedupe if the
  // shared core somehow didn't load, so the popup still works.
  const merged = M ? M.dedupeAndRank([...dom, ...sniffed]) : dedupe([...dom, ...sniffed]);
  const items = merged.sort((a, b) => (TYPE_RANK[a.type] ?? 9) - (TYPE_RANK[b.type] ?? 9));

  if (!items.length) { showEmpty(); return; }
  render(items, tab.url || "");
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
  // An adaptive <video> (blob:/MediaSource, no direct file) → offer "Download this video", which the
  // app resolves with yt-dlp into real quality tiers. location.href is the page handed off.
  const adaptive = [...document.querySelectorAll("video")].some((v) => !/^https?:/i.test(v.currentSrc || v.src || ""));
  if (adaptive) {
    const title = (document.title || "This video").replace(/\s*[-–|]\s*YouTube\s*$/i, "").trim();
    out.push({ url: location.href, type: "page", label: title || "This video", extract: true });
  }
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
    name.textContent = item.type === "page" ? "Download this video" : (item.label || item.url);
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
    await api.runtime.sendMessage({
      action: "download", url: item.url, audioUrl: item.audioUrl,
      referrer, filename: item.filename, extract: item.extract === true
    });
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
