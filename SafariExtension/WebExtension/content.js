// CloakDrop in-page widget — an IDM-style "Download" pill that appears on video/audio players (and a
// page-level pill for streams that have no visible player), so you never have to open the toolbar
// popup. It only appears when grabbable media is detected, and clicking a row hands the URL to the
// app's confirm banner — nothing is ever downloaded automatically.
//
// Runs in the content-script isolated world (top frame only). `media.js` loads before this file, so
// the shared classifier is on the global as `CloakDropMedia`.

(function () {
  "use strict";
  if (globalThis.__cloakdropWidgetLoaded) return;      // guard against double injection
  globalThis.__cloakdropWidgetLoaded = true;

  const api = globalThis.browser ?? globalThis.chrome;
  const M = globalThis.CloakDropMedia;
  if (!api || !M) return;

  const MIN_W = 180, MIN_H = 120;                      // ignore thumbnails / tiny inline players
  const ACCENT = "#5B4CE0";
  const ICON = '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true">' +
    '<path fill="currentColor" d="M8 1a.75.75 0 0 1 .75.75v6.19l1.72-1.72a.75.75 0 1 1 1.06 1.06l-3 3a.75.75 0 0 1-1.06 0l-3-3a.75.75 0 0 1 1.06-1.06l1.72 1.72V1.75A.75.75 0 0 1 8 1Z"/>' +
    '<path fill="currentColor" d="M2.5 10.5a.75.75 0 0 1 .75.75v1.5c0 .14.11.25.25.25h9a.25.25 0 0 0 .25-.25v-1.5a.75.75 0 0 1 1.5 0v1.5A1.75 1.75 0 0 1 12.5 14.5h-9A1.75 1.75 0 0 1 1.75 12.75v-1.5a.75.75 0 0 1 .75-.75Z"/></svg>';

  const CSS = `
    :host { all: initial; }
    .pill { position: fixed; z-index: 2147483000; display: inline-flex; align-items: center; gap: 5px;
      font: 600 12px/1 -apple-system, system-ui, "Segoe UI", sans-serif; color: #fff; background: ${ACCENT};
      border: 0; border-radius: 8px; padding: 6px 9px; cursor: pointer; opacity: .55;
      box-shadow: 0 1px 4px rgba(0,0,0,.35); transition: opacity .12s ease; user-select: none; }
    .pill:hover, .pill.open { opacity: 1; }
    .pill .cnt { background: rgba(255,255,255,.25); border-radius: 5px; padding: 1px 5px; font-size: 11px; }
    .menu { position: fixed; z-index: 2147483000; min-width: 230px; max-width: 340px; max-height: 320px;
      overflow-y: auto; background: Canvas; color: CanvasText; border: 1px solid rgba(128,128,128,.35);
      border-radius: 10px; padding: 5px; box-shadow: 0 6px 24px rgba(0,0,0,.28);
      font: 13px -apple-system, system-ui, "Segoe UI", sans-serif; }
    .row { display: flex; align-items: center; gap: 8px; padding: 7px 8px; border-radius: 7px; cursor: pointer; }
    .row:hover { background: color-mix(in srgb, ${ACCENT} 16%, transparent); }
    .chip { flex: none; width: 46px; text-align: center; font-size: 8.5px; font-weight: 700; letter-spacing: .3px;
      padding: 3px 0; border-radius: 4px; color: #fff; }
    .chip.stream { background: #C2410C; } .chip.video { background: ${ACCENT}; }
    .chip.audio { background: #0E7490; } .chip.file { background: #4B5563; } .chip.page { background: ${ACCENT}; }
    .meta { flex: 1; min-width: 0; } .name { font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .host { font-size: 11px; opacity: .6; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .row.sent .name::after { content: " · Sent ✓"; color: #16A34A; font-weight: 600; }
    .foot { display: flex; justify-content: space-between; align-items: center; gap: 10px; padding: 4px 6px 2px; }
    .foot button { font: inherit; font-size: 11px; color: inherit; opacity: .6; background: none; border: 0; cursor: pointer; }
    .foot button:hover { opacity: 1; text-decoration: underline; }`;

  // MARK: - State
  let tabMedia = [];                                   // streams/media the SW sniffed for this tab
  let disabled = false;                                // global or per-site off (persisted)
  let dismissed = false;                               // one-time hide for this view (not persisted)
  const videoWidgets = new Map();                      // HTMLMediaElement -> record
  let pageWidget = null;                               // fallback pill when no <video> anchors media
  let primaryPlayer = null;                            // the one player that carries page-global media
  let openMenu = null;                                 // the currently-open menu record

  // MARK: - Init
  (async function init() {
    try {
      const prefs = await api.storage.local.get(["widgetEnabled", "disabledHosts"]);
      const hidden = Array.isArray(prefs.disabledHosts) && prefs.disabledHosts.includes(location.host);
      disabled = prefs.widgetEnabled === false || hidden;
    } catch (_) { /* storage unavailable — default on */ }
    if (disabled) return;

    api.runtime.onMessage.addListener((msg) => {
      if (msg && msg.type === "cloakdrop:media") { tabMedia = msg.items || []; scheduleUpdate(); }
    });
    refreshFromBackground();

    const mo = new MutationObserver(scheduleUpdate);
    mo.observe(document.documentElement, { childList: true, subtree: true });
    window.addEventListener("scroll", scheduleReposition, { passive: true, capture: true });
    window.addEventListener("resize", scheduleReposition, { passive: true });
    // SPA navigations (YouTube etc.) don't reload — re-scan and re-pull the SW list.
    window.addEventListener("yt-navigate-finish", () => { dismissed = false; closeMenu(); refreshFromBackground(); });
    window.addEventListener("popstate", () => { dismissed = false; closeMenu(); refreshFromBackground(); });
    // Close the menu on any click outside it — but NOT on its own pill: this runs in the capture
    // phase (before the pill's bubble handler), so closing here on a pill click would let the pill
    // reopen it, making the toggle-to-close never work. Excluding the pill lets it toggle cleanly.
    document.addEventListener("click", (e) => {
      if (!openMenu) return;
      const path = e.composedPath();
      if (!path.includes(openMenu.menu) && !path.includes(openMenu.pill)) closeMenu();
    }, true);
    scheduleUpdate();
  })();

  async function refreshFromBackground() {
    try {
      const resp = await api.runtime.sendMessage({ action: "getMedia" });
      tabMedia = (resp && resp.items) || [];
    } catch (_) { tabMedia = tabMedia || []; }
    scheduleUpdate();
  }

  // MARK: - Update loop (debounced + rAF-throttled)
  let updateQueued = false, reposQueued = false;
  function scheduleUpdate() { if (updateQueued) return; updateQueued = true; setTimeout(() => { updateQueued = false; update(); }, 120); }
  function scheduleReposition() { if (reposQueued) return; reposQueued = true; requestAnimationFrame(() => { reposQueued = false; repositionAll(); }); }

  function update() {
    if (disabled || dismissed) return;
    const videos = [...document.querySelectorAll("video, audio")].filter(isRealPlayer);
    // The single primary player anchors the page-global media (sniffed streams + the yt-dlp page
    // fallback), so an adaptive site like YouTube shows one pill, not a duplicate on every stray
    // <video>. Recomputed here each pass so it tracks resizes and SPA navigations.
    primaryPlayer = choosePrimary(videos);

    // Attach/refresh a pill on each real player that has something grabbable.
    const live = new Set();
    for (const v of videos) {
      if (!itemsFor(v).length) continue;
      live.add(v);
      if (!videoWidgets.has(v)) mountVideoWidget(v);
    }
    // Tear down widgets whose player vanished or lost its media.
    for (const [v, rec] of videoWidgets) { if (!live.has(v)) { destroy(rec); videoWidgets.delete(v); } }

    // Page-level fallback: streams/audio with no visible <video> to anchor to.
    const wantPage = !videos.length && tabMedia.length > 0;
    if (wantPage && !pageWidget) pageWidget = mountPageWidget();
    else if (!wantPage && pageWidget) { destroy(pageWidget); pageWidget = null; }
    if (pageWidget) pageWidget.render(tabMedia);

    repositionAll();
  }

  function repositionAll() {
    for (const [v, rec] of videoWidgets) positionOnVideo(rec, v);
    if (pageWidget) positionPage(pageWidget);
  }

  // MARK: - Grabbable items
  function isRealPlayer(el) {
    const r = el.getBoundingClientRect();
    if (el.tagName.toLowerCase() === "audio") return el.offsetParent !== null || r.width > 0;
    return r.width >= MIN_W && r.height >= MIN_H && el.offsetParent !== null;
  }
  function directSrc(el) { const s = el.currentSrc || el.src || ""; return /^https?:/i.test(s) ? s : ""; }
  // A player's grab list. Its own direct file (if any) is always shown. The page-GLOBAL media — the
  // streams the SW sniffed and the yt-dlp page fallback — belongs only to the primary player, so a
  // site with several <video>s (YouTube's main player + hover-preview thumbnails + miniplayer, all
  // blob/MediaSource and all resolving to the same page URL) never stacks an identical pill on each.
  function itemsFor(el) {
    const src = directSrc(el);
    const isVideo = el.tagName.toLowerCase() === "video";
    const own = src ? [M.makeItem(src, isVideo ? "video" : "audio", { source: "dom" })] : [];
    const list = M.dedupeAndRank(own.concat(el === primaryPlayer ? tabMedia : []));
    // An adaptive player (blob:/MediaSource, no direct file) can't be grabbed by URL — offer page
    // extraction (the app's bundled yt-dlp), but only on the primary so it appears exactly once.
    if (el === primaryPlayer && !src && isVideo) list.push(pageItem());
    return list;
  }

  // The primary player: the largest visible <video>, or the largest <audio> when the page has no
  // video. Uses the shared, unit-tested ranking rule so the "one pill per page" behaviour is testable
  // outside the browser. Null when there are no players.
  function choosePrimary(players) {
    const descriptors = players.map((el) => {
      const r = el.getBoundingClientRect();
      return { video: el.tagName.toLowerCase() === "video", area: r.width * r.height };
    });
    const idx = M.primaryPlayerIndex(descriptors);
    return idx >= 0 ? players[idx] : null;
  }

  // A "grab this whole page's video via the app" item — the app resolves it with yt-dlp into real
  // quality tiers and downloads the best (with audio). The title is a display hint; the app uses the
  // real title yt-dlp reports.
  function pageItem() {
    const title = (document.title || "This video").replace(/\s*[-–|]\s*YouTube\s*$/i, "").trim();
    return { url: location.href, type: "page", label: title || "This video", extract: true, filename: title };
  }

  // MARK: - Widgets
  function makeShadowHost() {
    const host = document.createElement("div");
    host.style.cssText = "all: initial; position: static;";
    const shadow = host.attachShadow({ mode: "open" });
    try { const s = new CSSStyleSheet(); s.replaceSync(CSS); shadow.adoptedStyleSheets = [s]; }
    catch (_) { const s = document.createElement("style"); s.textContent = CSS; shadow.appendChild(s); }
    (document.body || document.documentElement).appendChild(host);
    return { host, shadow };
  }

  function mountVideoWidget(video) {
    const { host, shadow } = makeShadowHost();
    const pill = pillButton();
    shadow.appendChild(pill);
    const rec = { host, shadow, pill, menu: null, itemsOf: () => itemsFor(video) };
    pill.addEventListener("click", (e) => { e.stopPropagation(); toggleMenu(rec, pill); });
    videoWidgets.set(video, rec);
    positionOnVideo(rec, video);
    return rec;
  }

  function mountPageWidget() {
    const { host, shadow } = makeShadowHost();
    const pill = pillButton();
    shadow.appendChild(pill);
    const rec = { host, shadow, pill, menu: null, itemsOf: () => tabMedia, render(items) { pill.querySelector(".cnt").textContent = String(items.length); } };
    pill.addEventListener("click", (e) => { e.stopPropagation(); toggleMenu(rec, pill); });
    positionPage(rec);
    return rec;
  }

  function pillButton() {
    const b = document.createElement("button");
    b.className = "pill";
    b.innerHTML = ICON + '<span>Save</span><span class="cnt">1</span>';
    return b;
  }

  function positionOnVideo(rec, video) {
    const r = video.getBoundingClientRect();
    const off = r.width < MIN_W || r.height < MIN_H || r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth;
    rec.pill.style.display = off ? "none" : "inline-flex";
    if (off) { if (rec.menu) closeMenu(); return; }
    rec.pill.querySelector(".cnt").textContent = String(rec.itemsOf().length);
    rec.pill.style.top = Math.max(6, r.top + 8) + "px";
    rec.pill.style.left = Math.min(innerWidth - 90, r.right - 90) + "px";
    if (rec.menu) placeMenu(rec);
  }

  function positionPage(rec) {
    rec.pill.querySelector(".cnt").textContent = String(tabMedia.length);
    rec.pill.style.top = "";
    rec.pill.style.bottom = "18px";
    rec.pill.style.left = "";
    rec.pill.style.right = "18px";
    if (rec.menu) placeMenu(rec);
  }

  // MARK: - Menu
  function toggleMenu(rec, pill) {
    if (rec.menu) { closeMenu(); return; }
    closeMenu();
    const items = rec.itemsOf();
    if (!items.length) return;
    const menu = document.createElement("div");
    menu.className = "menu";
    for (const item of items) menu.appendChild(menuRow(rec, item));
    const foot = document.createElement("div");
    foot.className = "foot";
    const dismiss = document.createElement("button");
    dismiss.textContent = "Dismiss";
    dismiss.title = "Hide until you reload or open another video";
    dismiss.addEventListener("click", (e) => { e.stopPropagation(); dismissOnce(); });
    const hide = document.createElement("button");
    hide.textContent = "Hide on this site";
    hide.addEventListener("click", (e) => { e.stopPropagation(); hideOnThisSite(); });
    foot.append(dismiss, hide);
    menu.appendChild(foot);
    rec.shadow.appendChild(menu);
    rec.menu = menu;
    pill.classList.add("open");
    openMenu = rec;
    placeMenu(rec);
  }

  function menuRow(rec, item) {
    const row = document.createElement("div");
    row.className = "row";
    const chip = document.createElement("span");
    chip.className = "chip " + item.type;
    chip.textContent = item.type === "page" ? "VIDEO" : (M.TYPE_LABEL[item.type] || "FILE");
    const meta = document.createElement("div");
    meta.className = "meta";
    const name = document.createElement("div");
    name.className = "name";
    name.textContent = item.type === "stream" ? (item.label || "Stream") + "  ·  pick quality in app"
      : item.type === "page" ? "Download this video"
      : (item.label || item.url);
    const host = document.createElement("div");
    host.className = "host";
    host.textContent = M.hostOf(item.url);
    meta.append(name, host);
    row.append(chip, meta);
    row.addEventListener("click", (e) => { e.stopPropagation(); handOff(item, row); });
    return row;
  }

  function placeMenu(rec) {
    const p = rec.pill.getBoundingClientRect();
    rec.menu.style.top = Math.min(innerHeight - 60, p.bottom + 6) + "px";
    rec.menu.style.left = Math.max(8, Math.min(innerWidth - 348, p.left - 200)) + "px";
  }

  function closeMenu() {
    if (!openMenu) return;
    if (openMenu.menu) { openMenu.menu.remove(); openMenu.menu = null; }
    openMenu.pill.classList.remove("open");
    openMenu = null;
  }

  function handOff(item, row) {
    api.runtime.sendMessage({
      action: "download", url: item.url, audioUrl: item.audioUrl,
      referrer: location.href, filename: item.filename, extract: item.extract === true
    });
    row.classList.add("sent");
    setTimeout(closeMenu, 700);
  }

  async function hideOnThisSite() {
    try {
      const prefs = await api.storage.local.get(["disabledHosts"]);
      const hosts = new Set(Array.isArray(prefs.disabledHosts) ? prefs.disabledHosts : []);
      hosts.add(location.host);
      await api.storage.local.set({ disabledHosts: [...hosts] });
    } catch (_) { /* ignore */ }
    disabled = true;
    teardownAll();
  }

  // A one-time hide for this view only. Unlike "Hide on this site" nothing is persisted — the pill
  // returns on reload, or when a SPA navigation loads another video (the nav handlers reset this).
  function dismissOnce() {
    dismissed = true;
    teardownAll();
  }

  // Remove every mounted pill/menu — shared by the permanent hide and the one-time dismiss.
  function teardownAll() {
    closeMenu();
    for (const [, rec] of videoWidgets) destroy(rec);
    videoWidgets.clear();
    if (pageWidget) { destroy(pageWidget); pageWidget = null; }
  }

  function destroy(rec) { if (openMenu === rec) closeMenu(); rec.host.remove(); }
})();
