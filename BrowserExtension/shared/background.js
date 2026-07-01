// CloakDrop — cross-browser (Chrome / Edge / Firefox) background script, MV3.
//
// Mirrors the bundled Safari extension: it adds "Download with CloakDrop" to the link and media
// (video/audio/image) context menus, and when chosen gathers just enough to reproduce the browser's
// request for THAT download — the page URL as referrer, the user-agent, and the cookies scoped to
// the target — then hands it to the native app.
//
// The channel here is a native-messaging host (see NativeMessagingHost/): `sendNativeMessage` wakes
// the small helper bundled in CloakDrop.app, which drops the capture into the app's shared inbox.
// That fatter channel exists because a large `Cookie` header can exceed the `cloakdrop://` URL
// length. If the host isn't installed, or has no shared container (an unsigned/dev build), we fall
// back to the deep link. Either way the app shows a confirm banner before anything is queued.
//
// Privacy: nothing here leaves the device. The native message goes only to the containing app;
// cookies are read for the specific download URL and forwarded once, never stored by the extension.

// Firefox exposes `browser` (promises); Chrome/Edge expose `chrome` (promises in MV3). One shim
// covers all three.
const api = globalThis.browser ?? globalThis.chrome;

// Must match the native host manifest's "name" and the installer (NativeMessagingInstaller).
const HOST_NAME = "com.cloakyard.cloakdrop";
const MENU_LINK = "cloakdrop-link";
const MENU_MEDIA = "cloakdrop-media";

api.runtime.onInstalled.addListener(() => {
  api.contextMenus.removeAll(() => {
    api.contextMenus.create({
      id: MENU_LINK,
      title: "Download with CloakDrop",
      contexts: ["link"]
    });
    api.contextMenus.create({
      id: MENU_MEDIA,
      title: "Download with CloakDrop",
      contexts: ["video", "audio", "image"]
    });
  });
});

api.contextMenus.onClicked.addListener((info, tab) => {
  const target = info.menuItemId === MENU_LINK ? info.linkUrl : info.srcUrl;
  if (!target) return;
  const referrer = info.pageUrl || (tab && tab.url) || "";
  capture(target, referrer);
});

async function capture(target, referrer) {
  const payload = {
    url: target,
    referrer: referrer,
    userAgent: navigator.userAgent,
    cookies: await cookieHeader(target),
    filename: fileNameFromURL(target)
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
