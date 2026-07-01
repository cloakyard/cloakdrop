# CloakDrop browser extension (Chrome · Edge · Firefox)

The cross-browser sibling of the bundled Safari extension. It adds **Download with CloakDrop** to
the link and media context menus and hands each capture to CloakDrop, carrying the page's referrer,
user-agent, and the cookies scoped to that download — so gated files download correctly.

Everything stays on device: the extension talks only to the local app, never the network.

## Layout

```
shared/            background.js, popup.html, icons — the single source of truth
manifest.chrome.json    Chrome & Edge manifest (MV3, service worker). Pins the extension ID via "key".
manifest.firefox.json   Firefox manifest (MV3, event page + gecko id).
package.sh              Stitches shared/ + a manifest into dist/chrome and dist/firefox.
```

Run `./package.sh` (add `--zip` for distributable archives) to produce the loadable folders under
`dist/`.

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

Then enable the native host from CloakDrop ▸ Settings ▸ Browsers and right-click a link → **Download
with CloakDrop**.

> Native-messaging hosts can't be sandboxed, so this path ships in the **Developer ID (direct
> download)** build of CloakDrop, not the Mac App Store build. The bundled **Safari** extension
> (which uses the same shared inbox through a sandboxed app-extension) is the App-Store-friendly
> capture path.
