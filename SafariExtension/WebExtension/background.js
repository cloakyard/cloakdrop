// CloakDrop — cross-browser (Chrome / Edge / Firefox / Safari) background script, MV3.
//
// Three ways a download reaches the app:
//   1. Right-click a link/video/audio/image → "Download with CloakDrop" (context menu).
//   2. Open the toolbar popup, which lists media detected on the current tab — both the media
//      already in the page's DOM and any streaming manifests (HLS `.m3u8` / DASH `.mpd`), media
//      responses, or attachment downloads seen going over the wire, which the DOM never exposes.
//      This script is the sniffer for that second path: it watches the tab's network requests and
//      keeps a per-tab list.
//   3. IDM-style takeover: a browser download of a type the app handles (archive/installer/media/
//      PDF) is cancelled and handed to the app instead — see the interception section below.
//      Feature-detected (Safari has no downloads API) and toggleable from the popup.
//
// Either way, choosing a download gathers just enough to reproduce the browser's request for THAT
// resource — the page URL as referrer, the user-agent, and the cookies scoped to the target — then
// hands it to the native app, which starts the download immediately (no extra confirm). A "page"
// hand-off (the in-page pill's "Download this video") passes the page URL with an `extract` flag; the
// app resolves it with its bundled yt-dlp into real quality tiers and grabs the best one.
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

// Shared media classifier/filter (dedupe, noise-filtering, content-type/URL classification). Chrome
// and Safari run this file as a classic service worker, so we pull the core in with importScripts;
// Firefox's MV3 background has no importScripts and instead lists media.js ahead of background.js in
// `background.scripts` (see manifest.firefox.json). Either way it lands on the global as
// `CloakDropMedia`.
if (typeof importScripts === "function") { try { importScripts("media.js"); } catch (_) { /* already loaded */ } }
const M = globalThis.CloakDropMedia;

// Must match the native host manifest's "name" and the installer (NativeMessagingInstaller).
const HOST_NAME = "com.cloakyard.cloakdrop";
const MENU_LINK = "cloakdrop-link";
const MENU_MEDIA = "cloakdrop-media";
const MAX_ITEMS_PER_TAB = 60;

// Detected streaming/media URLs seen on the wire, keyed by tab id, then by a canonical record key
// (host+path for extension-carrying media, so a signed CDN URL that rotates its token doesn't show
// twice — see media.js `recordKey`). Cleared per tab on navigation, including SPA pushState navs.
//
// MV3 evicts an idle service worker and would wipe this map — the classic "opened the popup two
// minutes later and it's empty" failure. Every mutation is mirrored into `storage.session`
// (memory-backed, cleared when the browser quits, never written to disk — consistent with the
// privacy posture), and a fresh worker instance restores it lazily before answering queries.
const mediaByTab = new Map();
const session = api.storage && api.storage.session;

// Resolves once a freshly-woken worker has merged any state a previous instance persisted.
const restored = (async () => {
  if (!session) return;
  try {
    const all = await session.get(null);
    for (const [key, value] of Object.entries(all || {})) {
      if (!key.startsWith("media:") || !Array.isArray(value)) continue;
      const tabId = Number(key.slice("media:".length));
      if (!mediaByTab.has(tabId)) mediaByTab.set(tabId, new Map(value));
    }
  } catch (_) { /* storage.session unavailable — in-memory only */ }
})();

function persistTab(tabId) {
  if (!session) return;
  const forTab = mediaByTab.get(tabId);
  try {
    const write = forTab && forTab.size
      ? session.set({ ["media:" + tabId]: Array.from(forTab.entries()) })
      : session.remove("media:" + tabId);
    if (write && write.catch) write.catch(() => {});
  } catch (_) { /* ignore */ }
}

function clearTab(tabId) {
  mediaByTab.delete(tabId);
  persistTab(tabId);
  updateBadge(tabId);
}

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
    const item = M.classifyByURL(details.url);
    if (item) record(details.tabId, item);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other", "object", "sub_frame"] }
);

// Record media discovered by response headers: content-type (manifests/streams often have no file
// extension on the URL but declare their type), an explicit `Content-Disposition: attachment` (the
// server saying "this is a download"), and Content-Length to drop sub-1 KB "media" (UI sounds /
// beacons) that slip past the URL filter. Only successful responses — a 403's error page or an
// expired-token redirect must not enter the list.
api.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.statusCode !== 200 && details.statusCode !== 206) return;
    const contentType = headerValue(details.responseHeaders, "content-type");
    const disposition = headerValue(details.responseHeaders, "content-disposition");
    const contentLength = Number(headerValue(details.responseHeaders, "content-length")) || undefined;
    const item = M.classifyByContentType(details.url, contentType, contentLength, disposition);
    if (item) record(details.tabId, item);
  },
  { urls: ["<all_urls>"], types: ["media", "xmlhttprequest", "other", "object", "sub_frame"] },
  ["responseHeaders"]
);

// Drop a tab's list when it navigates to a new page (or is closed) so stale hits don't linger.
const lastTabURL = new Map();   // tabId → last committed URL sans fragment (SPA-nav detection)
api.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (details.type === "main_frame") {
      lastTabURL.set(details.tabId, String(details.url).split("#")[0]);
      clearTab(details.tabId);
    }
  },
  { urls: ["<all_urls>"], types: ["main_frame"] }
);
// SPA navigations (YouTube's next video, TikTok's scroll) never issue a main_frame request — the
// URL changes via pushState. Without this, the previous video's streams linger in the new page's
// list. Fragment-only changes (`#t=42`) are not navigations and must NOT clear anything.
api.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (!changeInfo.url) return;
  const withoutFragment = changeInfo.url.split("#")[0];
  const previous = lastTabURL.get(tabId);
  lastTabURL.set(tabId, withoutFragment);
  if (previous !== undefined && previous !== withoutFragment) clearTab(tabId);
});
api.tabs.onRemoved.addListener((tabId) => { lastTabURL.delete(tabId); clearTab(tabId); });

function record(tabId, item) {
  if (tabId < 0) return;                       // not tied to a tab (e.g. the extension's own fetches)
  let forTab = mediaByTab.get(tabId);
  if (!forTab) { forTab = new Map(); mediaByTab.set(tabId, forTab); }
  const key = M.recordKey(item.url);
  const isNew = !forTab.has(key);
  if (isNew && forTab.size >= MAX_ITEMS_PER_TAB) return;
  // A repeat of the same resource (rotated CDN token) overwrites in place: the freshest URL is the
  // one most likely to still be valid when the user clicks, and Map keeps the original position.
  forTab.set(key, item);
  persistTab(tabId);
  if (isNew) { updateBadge(tabId); notifyTab(tabId); }
}

// The tab's detected media as a plain array (deduped/ordered), shared by the popup and content script.
function mediaList(tabId) {
  const forTab = mediaByTab.get(tabId);
  return forTab ? M.dedupeAndRank(Array.from(forTab.values())) : [];
}

// Push the current list to the tab's in-page widget so it updates live — not only when the popup is
// opened. Throttled per tab (~300 ms) and silently ignored on pages with no content script
// (chrome:// pages, the web store, the PDF viewer).
const notifyTimers = new Map();
function notifyTab(tabId) {
  if (tabId < 0 || notifyTimers.has(tabId)) return;
  notifyTimers.set(tabId, setTimeout(() => {
    notifyTimers.delete(tabId);
    const items = mediaList(tabId);
    if (!items.length) return;
    try {
      const sent = api.tabs.sendMessage(tabId, { type: "cloakdrop:media", items });
      if (sent && sent.catch) sent.catch(() => {});   // no receiver on this page — fine
    } catch (_) { /* restricted page */ }
  }, 300));
}

function updateBadge(tabId) {
  // Count what the user actually sees — the deduped, rendition-collapsed list — not every raw wire
  // hit (a single video spawns many variant/segment URLs).
  const count = mediaList(tabId).length;
  try {
    api.action.setBadgeText({ tabId, text: count ? String(count) : "" });
    api.action.setBadgeBackgroundColor({ tabId, color: "#5B4CE0" });
  } catch (_) { /* action.badge unsupported in this browser — the popup list still works */ }
}

// MARK: - Popup messaging

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  // `return true` keeps the response channel open — the one pattern that delivers a reply on both
  // Chrome (which ignores a returned Promise) and Firefox.
  if (message?.action === "getMedia") {
    // The popup passes an explicit tabId; the content script omits it and we read its own tab.
    // Await the session-storage restore first, so a freshly-woken worker doesn't answer "nothing"
    // from a not-yet-refilled map.
    const tabId = message.tabId ?? sender?.tab?.id;
    restored.then(() => sendResponse({ items: tabId == null ? [] : mediaList(tabId) }));
    return true;
  }
  if (message?.action === "download") {
    capture(message.url, message.referrer || "", message.filename, message.audioUrl, message.extract);
    sendResponse({ ok: true });
    return true;
  }
  return false;                                // not one of ours
});

// MARK: - Browser-download interception (IDM-style takeover)
//
// When the browser starts a normal download of a type the app handles (archives, installers,
// media, PDFs — see media.js `interceptable`), cancel it and hand the URL to CloakDrop, which
// downloads it multi-segment with resume. Guarantees:
//   • Feature-detected: Safari has no `downloads` API — everything else still works there.
//   • Off switch: the popup's "Catch browser downloads" toggle (storage.local, default on).
//   • Never lose a file: the hand-off uses the native host ONLY (no cloakdrop:// fallback — the
//     scheme can't report failure); if the app isn't reachable, the download is re-issued to the
//     browser untouched, marked to bypass re-interception.
//   • Never intercept blind: unknown types, blob:/data: URLs, and other extensions' downloads pass.
let interceptEnabled = true;
try {
  api.storage.local.get("interceptDownloads").then((prefs) => {
    if (prefs && prefs.interceptDownloads === false) interceptEnabled = false;
  }).catch(() => {});
} catch (_) { /* storage unavailable — default on */ }
api.storage.onChanged.addListener((changes, area) => {
  if (area === "local" && changes.interceptDownloads) {
    interceptEnabled = changes.interceptDownloads.newValue !== false;
  }
});

const bypassOnce = new Set();   // URLs we re-issued ourselves after a failed hand-off

if (api.downloads && api.downloads.onCreated) {
  api.downloads.onCreated.addListener(async (item) => {
    if (!interceptEnabled) return;
    const url = item.finalUrl || item.url || "";
    if (bypassOnce.delete(url)) return;                     // our own re-issue — let the browser keep it
    if (item.byExtensionId) return;                         // another extension's download
    // `filename` is the on-disk path when known; only its basename matters for classification.
    const basename = item.filename ? String(item.filename).split(/[\\/]/).pop() : "";
    if (!M.interceptable(url, basename, item.mime)) return;
    try { await api.downloads.cancel(item.id); } catch (_) { return; }   // already finished — leave it
    try { await api.downloads.erase({ id: item.id }); } catch (_) { /* history entry stays — harmless */ }
    const handedOff = await capture(url, item.referrer || "", basename || undefined,
      undefined, false, { allowSchemeFallback: false });
    if (!handedOff) {
      // App unreachable — give the download back to the browser exactly as it was.
      bypassOnce.add(url);
      try { await api.downloads.download({ url }); } catch (_) { bypassOnce.delete(url); }
    }
  });
}

// MARK: - Classification
//
// URL/content-type classification, noise filtering, and dedupe now live in the shared media core
// (media.js → `M.*`), so the popup, content script, and this worker all agree and the logic is
// unit-tested under Node. googlevideo traffic is filtered as noise here; the YouTube player-data
// extraction that lists real resolutions lives in the popup/content path.

function headerValue(headers, name) {
  if (!headers) return "";
  const wanted = name.toLowerCase();
  for (const h of headers) { if (h.name.toLowerCase() === wanted) return h.value || ""; }
  return "";
}

// MARK: - Hand-off to the app (shared by both paths)

// Hand a download to the app. Returns true when it was delivered (native host confirmed, or the
// cloakdrop:// deep link was opened), false only when `allowSchemeFallback` is off and the native
// host failed — the interception path uses that to give the download back to the browser.
async function capture(target, referrer, filenameOverride, audioURL, extractFromPage, options) {
  const payload = {
    url: target,
    referrer: referrer,
    userAgent: navigator.userAgent,
    cookies: await cookieHeader(target),
    // A caller-supplied name (e.g. a video title) wins over the URL's — a googlevideo URL has no
    // usable filename of its own.
    filename: filenameOverride || M.fileNameFromURL(target)
  };
  // Adaptive grab (e.g. a higher-res YouTube rendition): a separate audio-only URL the app downloads
  // alongside the video and muxes in, so the file has sound. Absent for a normal single-file download.
  if (audioURL) payload.audioURL = audioURL;
  // A "page" hand-off: `target` is a page URL (a YouTube watch page, etc.); the app runs its bundled
  // yt-dlp to resolve it into real quality tiers, then grabs the best one (with audio). The cookies
  // gathered above let it authenticate exactly as the browser did.
  if (extractFromPage) payload.extract = true;
  // Preferred path: the native host relays into the shared App Group inbox (carries big cookies).
  // On any failure — host not installed, or a dev build without the shared container — fall back to
  // the cloakdrop:// deep link, which needs no shared container.
  try {
    const response = await api.runtime.sendNativeMessage(HOST_NAME, payload);
    if (response && response.ok) return true;
    console.warn("CloakDrop host unavailable, using URL scheme:", response && response.error);
  } catch (error) {
    console.warn("CloakDrop native message failed, using URL scheme:", error);
  }
  if (options && options.allowSchemeFallback === false) return false;
  openViaURLScheme(payload);
  return true;
}

// Fallback hand-off: open `cloakdrop://add?…`. Works without the native host. Cookies ride the query,
// so very large cookie headers may hit URL-length limits — that's why native messaging is preferred.
function openViaURLScheme(p) {
  const params = new URLSearchParams();
  params.set("url", p.url);
  if (p.audioURL) params.set("audio", p.audioURL);
  if (p.extract) params.set("extract", "1");
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
