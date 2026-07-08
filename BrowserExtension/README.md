# CloakDrop browser extension (Chrome · Edge · Brave · Firefox)

The cross-browser sibling of the bundled Safari extension. Three ways a download reaches CloakDrop:

- **Context menu** — right-click any link, video, audio, or image → **Download with CloakDrop**.
- **Toolbar popup** — lists the downloadable media detected on the current tab and sends any of it
  with one click. Detection merges two sources: media already in the page's DOM (`<video>`/`<audio>`/
  `<source>` and direct media/file links, scanned on demand only when you open the popup) and the
  streaming manifests (HLS `.m3u8` / DASH `.mpd`), media responses, or `Content-Disposition:
  attachment` downloads the background script sees go past on the network — which the DOM never
  exposes. A badge shows how many were found. Detection survives MV3 service-worker eviction
  (mirrored into `storage.session` — memory-backed, never on disk) and clears on real *and* SPA
  navigations, so yesterday's video never haunts today's list.
- **Download takeover (IDM-style)** — a browser download of a type the app handles (archives,
  installers, media, PDFs) is cancelled and handed to the app, which downloads it multi-segment
  with resume. Feature-detected (Safari has no `downloads` API), toggleable from the popup, and
  fail-safe: if the app isn't reachable the download is re-issued to the browser untouched — a
  file is never lost to a broken hand-off.

Detection runs in **every frame**, not just the top document (`all_frames` content script + the
background's `sub_frame` webRequest view) — so media inside embedded players (Vimeo, JW Player,
Brightcove iframes), where much of the web's video actually lives, is caught too.

Either way, the capture carries the page's referrer, user-agent, and the cookies scoped to that
download — so gated files download correctly — and a streaming manifest is resolved by the app into
a quality picker.

Everything stays on device: the extension talks only to the local app, never the network. Detected
URLs live only in the background script's memory (per tab, cleared on navigation); cookies are read
for the chosen download only and forwarded once to the app, never stored, never sent elsewhere.

## Layout

```
shared/            background.js, popup.html, popup.js, icons — the single source of truth
manifest.chrome.json    Chrome & Edge manifest (MV3, service worker). Pins the extension ID via "key".
manifest.firefox.json   Firefox manifest (MV3, event page + gecko id; min 128 for scripting `func`).
package.sh              Stitches shared/ + a manifest into dist/chrome and dist/firefox.
```

Detection needs `webRequest` (observe stream/media responses), `scripting` (inject the on-demand DOM
scan), `tabs` (identify the active tab), and `downloads` (the takeover) on top of the original
`contextMenus`/`cookies`/`activeTab`/`nativeMessaging`. `webRequest` is observational only (no
blocking), so it stays MV3-clean.

Run `./package.sh` (add `--zip` for distributable archives) to produce the loadable folders under
`dist/`.

## Testing

- `./test.sh` — unit tests for the shared classifier (`shared/media.js`) under Node's built-in
  runner: classification, noise filtering, rendition/playlist/segment collapsing, HLS+DASH twin
  folding, record-key canonicalisation, interception rules.
- `./e2e.sh` — loads `dist/chrome` into a cached **Chrome for Testing** (set `CHROME_BIN` to
  override discovery) against a local crafted page, and asserts the deduped popup list, the single
  in-page pill, and the interception → bypass re-download safety net, over raw CDP with zero npm
  dependencies.

## How the hand-off works

1. `background.js` gathers the capture and calls `runtime.sendNativeMessage("com.cloakyard.cloakdrop", …)`.
2. The **native-messaging host** (`CloakDropNativeHost`, bundled in `CloakDrop.app`) validates the
   capture and drops it in the shared **App Group** inbox, then posts a Darwin wake signal.
3. The app drains the inbox and shows its confirm banner.

The native host is the fatter channel that carries large `Cookie` headers the `cloakdrop://` URL
scheme can't. If the host isn't installed — or the app is an unsigned/dev build without the shared
container — the extension falls back to opening `cloakdrop://add?…`.

**Enable the host from the app:** CloakDrop ▸ Settings ▸ **Browsers** installs the native-messaging
manifest for each browser you pick (a guided, sandbox-safe folder grant — see
`NativeMessagingInstaller`).

## Identifiers (kept in lockstep across the manifests, the host, and the installer)

| Thing | Value |
| --- | --- |
| Native host name | `com.cloakyard.cloakdrop` |
| Chrome / Edge extension ID | `mhkmioglakbnadmifmcbjjmoolinoopg` (pinned by the `key` in `manifest.chrome.json`) |
| Firefox add-on ID | `cloakdrop@cloakyard.com` |

The Chrome/Edge ID is derived from the committed public `key`; the matching **private** key is *not*
in the repo (it's only needed to publish a signed `.crx` to the Web Store — "Load unpacked" reads
the `key` field directly). Regenerate with:

```bash
openssl genrsa 2048 > key.pem
openssl rsa -in key.pem -pubout -outform DER | base64   # → the manifest "key" field
```

## Loading for development

- **Chrome / Edge:** `./package.sh`, then `chrome://extensions` → enable Developer mode → **Load
  unpacked** → select `dist/chrome`. The ID will be `mhkmioglakbnadmifmcbjjmoolinoopg`.
- **Firefox:** `./package.sh`, then `about:debugging` → This Firefox → **Load Temporary Add-on** →
  select `dist/firefox/manifest.json`.

Then enable the native host from CloakDrop ▸ Settings ▸ Browsers. Right-click a link → **Download
with CloakDrop**, or open a page with video and click the CloakDrop toolbar button to pick from the
detected media.

> Native-messaging hosts can't be sandboxed, so this path ships in the **Developer ID (direct
> download)** build of CloakDrop, not the Mac App Store build. The bundled **Safari** extension
> (which uses the same shared inbox through a sandboxed app-extension) is the App-Store-friendly
> capture path.
