// CloakDrop — cross-browser (Chrome / Edge / Firefox) background script, MV3.
//
// Two ways to hand a download to the app:
//   1. Right-click a link/video/audio/image → "Download with CloakDrop" (context menu).
//   2. Open the toolbar popup, which lists media detected on the current tab — both the media
//      already in the page's DOM and any streaming manifests (HLS `.m3u8` / DASH `.mpd`) or media
//      responses seen going over the wire, which the DOM never exposes. This script is the sniffer
//      for that second path: it watches the tab's network requests and keeps a per-tab list.
//
// Either way, choosing a download gathers just enough to reproduce the browser's request for THAT
// resource — the page URL as referrer, the user-agent, and the cookies scoped to the target — then
// hands it to the native app, which shows a confirm banner before anything is queued.
//
// The channel is a native-messaging host (see NativeMessagingHost/): `sendNativeMessage` wakes the
// helper bundled in CloakDrop.app, which drops the capture into the app's shared inbox. That fatter
// channel exists because a large `Cookie` header can exceed the `cloakdrop://` URL length. If the
// host isn't installed, or has no shared container (an unsigned/dev build), we fall back to the deep
// link. For a streaming manifest the app resolves the renditions and shows a quality picker.
//
// Privacy: nothing here leaves the device. Detected URLs live only in this script's memory (a
// per-tab list, cleared on navigation); cookies are read for the specific download URL and forwarded
// once to the containing app, never stored by the extension, never sent anywhere else.

// Firefox exposes `browser` (promises); Chrome/Edge expose `chrome` (promises in MV3). One shim
// covers all three.
const api = globalThis.browser ?? globalThis.chrome;

// Must match the native host manifest's "name" and the installer (NativeMessagingInstaller).
const HOST_NAME = "com.cloakyard.cloakdrop";
const MENU_LINK = "cloakdrop-link";
const MENU_MEDIA = "cloakdrop-media";

// Streaming manifests (resolved by the app into a quality picker) and self-contained media files.
// Segment extensions are deliberately excluded from network sniffing so a stream's thousands of
// chunks don't flood the list — the manifest is what we want.
const STREAM_EXT = ["m3u8", "m3u", "mpd"];
const MEDIA_EXT = [
  "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "mpg", "mpeg", "3gp", "ogv",
  "mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"
];
const SEGMENT_EXT = ["ts", "m4s"];
const MAX_ITEMS_PER_TAB = 60;

// Detected streaming/media URLs seen on the wire, keyed by tab id, then by URL (dedup). In-memory:
// under MV3 the service worker can be evicted and this cleared, but ongoing segment traffic keeps it
// alive across a typical "load page → open popup" flow, and the popup's DOM scan is an independent
// second source. Cleared per tab on main-frame navigation.
const mediaByTab = new Map();

// MARK: - Context menu (unchanged path)

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.removeAll(() => {
    api.contextMenus.create({ id: MENU_LINK, title: "Download with CloakDrop", contexts: ["link"] });
    api.contextMenus.create({ id: MENU_MEDIA, title: "Download with CloakDrop", contexts: ["video", "audio", "image"] });
  });
});

api.contextMenus.onClicked.addListener((info, tab) => {
  const target = info.menuItemId === MENU_LINK ? info.linkUrl : info.srcUrl;
  if (!target) return;
  const referrer = info.pageUrl || (tab && tab.url) || "";
  capture(target, referrer);
});

// MARK: - Network sniffing (streams + media the DOM doesn't expose)

// Record media discovered by URL extension as each request starts.
api.webRequest.onBeforeRequest.addListener(
  (details) => {
    const item = classifyByURL(details.url);
    if (item) record(details.tabId, item);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other", "object", "sub_frame"] }
);

// Record media discovered by response content-type (manifests/streams often have no file extension
// on the URL — a query-string-only endpoint — but declare their type in the header).
api.webRequest.onHeadersReceived.addListener(
  (details) => {
    const contentType = headerValue(details.responseHeaders, "content-type");
    const item = classifyByContentType(details.url, contentType);
    if (item) record(details.tabId, item);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other", "object", "sub_frame"] },
  ["responseHeaders"]
);

// Drop a tab's list when it navigates to a new page (or is closed) so stale hits don't linger.
api.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (details.type === "main_frame") { mediaByTab.delete(details.tabId); updateBadge(details.tabId); }
  },
  { urls: ["<all_urls>"], types: ["main_frame"] }
);
api.tabs.onRemoved.addListener((tabId) => mediaByTab.delete(tabId));

function record(tabId, item) {
  if (tabId < 0) return;                       // not tied to a tab (e.g. the extension's own fetches)
  let forTab = mediaByTab.get(tabId);
  if (!forTab) { forTab = new Map(); mediaByTab.set(tabId, forTab); }
  if (forTab.has(item.url) || forTab.size >= MAX_ITEMS_PER_TAB) return;
  forTab.set(item.url, item);
  updateBadge(tabId);
}

function updateBadge(tabId) {
  const count = mediaByTab.get(tabId)?.size ?? 0;
  try {
    api.action.setBadgeText({ tabId, text: count ? String(count) : "" });
    api.action.setBadgeBackgroundColor({ tabId, color: "#5B4CE0" });
  } catch (_) { /* action.badge unsupported in this browser — the popup list still works */ }
}

// MARK: - Popup messaging

api.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  // `return true` keeps the response channel open — the one pattern that delivers a reply on both
  // Chrome (which ignores a returned Promise) and Firefox — even though we answer synchronously here.
  if (message?.action === "getMedia") {
    const forTab = mediaByTab.get(message.tabId);
    sendResponse({ items: forTab ? Array.from(forTab.values()) : [] });
    return true;
  }
  if (message?.action === "download") {
    capture(message.url, message.referrer || "", message.filename);
    sendResponse({ ok: true });
    return true;
  }
  return false;                                // not one of ours
});

// MARK: - Classification

// A media item derived from a URL alone, or null if the URL isn't recognisably media.
function classifyByURL(url) {
  if (isAdaptiveChunkNoise(url)) return null;
  const ext = extensionOf(url);
  if (!ext || SEGMENT_EXT.includes(ext)) return null;
  if (STREAM_EXT.includes(ext)) return makeItem(url, "stream");
  if (MEDIA_EXT.includes(ext)) return makeItem(url, audioExt(ext) ? "audio" : "video");
  return null;
}

// A media item derived from a response's content-type, for URLs without a telltale extension.
function classifyByContentType(url, contentType) {
  if (!contentType || isAdaptiveChunkNoise(url)) return null;
  const type = contentType.split(";")[0].trim().toLowerCase();
  const ext = extensionOf(url);
  if (ext && SEGMENT_EXT.includes(ext)) return null;   // never surface individual stream chunks
  if (type === "application/vnd.apple.mpegurl" || type === "application/x-mpegurl" || type === "application/dash+xml") {
    return makeItem(url, "stream");
  }
  if (type.startsWith("video/")) return makeItem(url, "video");
  if (type.startsWith("audio/")) return makeItem(url, "audio");
  return null;
}

function makeItem(url, type) {
  return { url, type, label: fileNameFromURL(url) || url };
}

// Hosts that serve chunked, signed adaptive streams (video and audio split, no manifest, URLs that
// expire and change per range) — surfacing raw chunks is useless. YouTube's googlevideo traffic is
// handled instead by the popup's player-response extractor, which lists real resolutions.
function isAdaptiveChunkNoise(url) {
  try { return new URL(url).hostname.endsWith("googlevideo.com"); } catch (_) { return false; }
}

function extensionOf(url) {
  try {
    const path = new URL(url).pathname;
    const last = path.split("/").pop() || "";
    const dot = last.lastIndexOf(".");
    return dot >= 0 ? last.slice(dot + 1).toLowerCase() : "";
  } catch (_) { return ""; }
}

function audioExt(ext) {
  return ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "weba"].includes(ext);
}

function headerValue(headers, name) {
  if (!headers) return "";
  const wanted = name.toLowerCase();
  for (const h of headers) { if (h.name.toLowerCase() === wanted) return h.value || ""; }
  return "";
}

// MARK: - Hand-off to the app (shared by both paths)

async function capture(target, referrer, filenameOverride) {
  const payload = {
    url: target,
    referrer: referrer,
    userAgent: navigator.userAgent,
    cookies: await cookieHeader(target),
    // A caller-supplied name (e.g. a YouTube video title) wins over the URL's — a googlevideo URL has
    // no usable filename of its own.
    filename: filenameOverride || fileNameFromURL(target)
  };
  // Preferred path: the native host relays into the shared App Group inbox (carries big cookies).
  // On any failure — host not installed, or a dev build without the shared container — fall back to
  // the cloakdrop:// deep link, which needs no shared container.
  try {
    const response = await api.runtime.sendNativeMessage(HOST_NAME, payload);
    if (response && response.ok) return;
    console.warn("CloakDrop host unavailable, using URL scheme:", response && response.error);
  } catch (error) {
    console.warn("CloakDrop native message failed, using URL scheme:", error);
  }
  openViaURLScheme(payload);
}

// Fallback hand-off: open `cloakdrop://add?…`. Works without the native host. Cookies ride the query,
// so very large cookie headers may hit URL-length limits — that's why native messaging is preferred.
function openViaURLScheme(p) {
  const params = new URLSearchParams();
  params.set("url", p.url);
  if (p.referrer) params.set("referer", p.referrer);
  if (p.userAgent) params.set("ua", p.userAgent);
  if (p.cookies) params.set("cookie", p.cookies);
  if (p.filename) params.set("filename", p.filename);
  api.tabs.create({ url: "cloakdrop://add?" + params.toString() });
}

// Build a "name=value; name=value" Cookie header from the cookies the browser holds for the target
// URL. Returns "" on any failure so the download still proceeds without cookies.
async function cookieHeader(target) {
  try {
    const cookies = await api.cookies.getAll({ url: target });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch (error) {
    return "";
  }
}

// Best-effort filename from the URL path; the app sanitizes and can still override it.
function fileNameFromURL(target) {
  try {
    const path = new URL(target).pathname;
    const last = path.split("/").filter(Boolean).pop() || "";
    return decodeURIComponent(last);
  } catch (error) {
    return "";
  }
}
