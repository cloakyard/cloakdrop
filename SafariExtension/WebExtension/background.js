// CloakDrop — Safari Web Extension background service worker.
//
// Adds "Download with CloakDrop" to the link and media (video/audio/image) context menus. When
// chosen, it gathers just enough context to reproduce the browser's request for THAT download —
// the page URL as referrer, the user-agent, and the cookies scoped to the target URL — and hands
// it to the native app via a native message. The app confirms before anything is queued.
//
// Privacy: nothing here leaves the device. The native message goes only to the containing app;
// cookies are read for the specific download URL and forwarded once, never stored by the extension.

const MENU_LINK = "cloakdrop-link";
const MENU_MEDIA = "cloakdrop-media";
// Safari routes native messages to the containing app regardless of this id; it's kept explicit
// for clarity and cross-browser parity.
const APP_ID = "com.cloakyard.cloakdrop.SafariExtension";

browser.runtime.onInstalled.addListener(() => {
  browser.contextMenus.removeAll(() => {
    browser.contextMenus.create({
      id: MENU_LINK,
      title: "Download with CloakDrop",
      contexts: ["link"]
    });
    browser.contextMenus.create({
      id: MENU_MEDIA,
      title: "Download with CloakDrop",
      contexts: ["video", "audio", "image"]
    });
  });
});

browser.contextMenus.onClicked.addListener((info, tab) => {
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
  // Preferred path: hand off natively to the app, which drops the capture in the shared App Group
  // inbox. That needs the App Group entitlement (present only in a team-signed build). When it's
  // unavailable — e.g. a team-less local/dev build — fall back to the `cloakdrop://` deep link,
  // which the app handles without any shared container. Either way the app shows a confirm banner.
  try {
    const response = await browser.runtime.sendNativeMessage(APP_ID, payload);
    if (response && response.ok) return;
    console.warn("CloakDrop inbox unavailable, using URL scheme:", response && response.error);
  } catch (error) {
    console.warn("CloakDrop native message failed, using URL scheme:", error);
  }
  openViaURLScheme(payload);
}

// Fallback hand-off: open `cloakdrop://add?…`. Works without App Groups. Cookies ride the query, so
// very large cookie headers may hit URL-length limits — that's why native messaging is preferred.
function openViaURLScheme(p) {
  const params = new URLSearchParams();
  params.set("url", p.url);
  if (p.referrer) params.set("referer", p.referrer);
  if (p.userAgent) params.set("ua", p.userAgent);
  if (p.cookies) params.set("cookie", p.cookies);
  if (p.filename) params.set("filename", p.filename);
  browser.tabs.create({ url: "cloakdrop://add?" + params.toString() });
}

// Build a "name=value; name=value" Cookie header from the cookies the browser holds for the target
// URL. Returns "" on any failure so the download still proceeds without cookies.
async function cookieHeader(target) {
  try {
    const cookies = await browser.cookies.getAll({ url: target });
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
