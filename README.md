# CloakDrop

**A fast, private, multi-segment download manager for macOS — that feels like Apple made it.**

Serious multi-segment download power with the look and feel of a first-party app. No Electron, no web views, no telemetry — everything runs on your Mac and nothing ever phones home.

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%C2%B7%20Apple%20silicon-lightgrey" alt="Platform: macOS · Apple silicon">
  <img src="https://img.shields.io/badge/status-beta-2A7B9B" alt="Status: beta">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-8A2BE2" alt="SwiftUI · Liquid Glass">
</p>

> Part of the **[Cloakyard](https://github.com/cloakyard)** privacy-first suite, alongside **CloakPDF**, **CloakIMG**, and **CloakResume**.

---

## 📥 Download & release timeline

**[⬇️ Download the beta](https://github.com/cloakyard/cloakdrop/releases/download/beta/CloakDrop-beta.dmg)** · Apple silicon · [all releases](https://github.com/cloakyard/cloakdrop/releases)

CloakDrop is in **active development**. The beta is a complete, usable app — but it is *not* notarized yet, so macOS will not open it on a double-click: **right-click the app ▸ Open** the first time, then it launches normally forever after.

| | |
|---|---|
| 🧪 **Beta — now** | Rolling pre-release, rebuilt as features land. Unsigned by Apple's notary service; the engine and its 471 tests are the same ones the stable build will ship. |
| 🍎 **Stable — with macOS 27 Golden Gate** | The first Developer ID-signed, **notarized** build is timed to Golden Gate's final release, not to a date of our own. |

**Why wait for Golden Gate?** CloakDrop is built from the ground up for **macOS 27 Golden Gate** — its UI is Liquid Glass all the way down, and that design language is still moving through the OS betas. Shipping a notarized 1.0 against a final Golden Gate means what you install is what was tested, on the finished glass, rather than a build chasing a moving target.

**Why Apple silicon only?** Golden Gate is an Apple-silicon-only release, so CloakDrop is **arm64-only** — there is no Intel or universal build, and there won't be one.

## ✨ What it does

| | |
|---|---|
| 🧵 **Multi-segment downloads** | Splits each file into parallel streams over HTTP Range (configurable, default 8) and reassembles byte-perfectly — with automatic single-stream fallback when a server doesn't support ranges. |
| 🔌 **HTTP, HTTPS & FTP/FTPS** | One engine, many transports — a native FTP/FTPS client (over Network.framework: EPSV/PASV, `REST` resume, implicit TLS for `ftps`) segments and resumes just like HTTP, with no bundled library. |
| ⏯️ **True pause & resume** | Real byte-range resume that survives app relaunch *and* reboot — it never re-downloads a byte. |
| 🔁 **Auto-recovery** | Per-segment retry with exponential backoff + jitter; auto-pauses when the network drops and resumes when it returns. |
| ✅ **Integrity & trust** | MD5 / SHA-1 / SHA-256 verification on completion — from a checksum you supply or auto-discovered from a sibling `.sha256`/`.sha1`/`.md5` — plus a code-signature/notarization trust check on `.app`/`.dmg`. |
| 🧾 **Provenance Receipt** | Every completed download gets a local, exportable *verified-download record* — sources, TLS, whole-file SHA-256, and checksum + signature verdicts in one trust verdict. No other download manager produces one. |
| 🐢 **Bandwidth control** | Global **and** per-download speed limits (a GCRA throttle that holds the aggregate cap honestly under many concurrent connections), plus optional time-of-day profiles. |
| 🗂️ **Queues, categories & rules** | Per-queue concurrency limits, smart filters, a rule-based routing engine (folder / queue / speed cap / auto-start), duplicate detection, and auto-sorting of finished files into per-type folders. |
| 📦 **Post-processing** | Native ZIP auto-extraction (Zip-Slip + decompression-bomb guarded), a Gatekeeper quarantine flag on saved files, and post-download actions (notify / quit / run a Shortcut). |
| 📋 **Effortless capture** | Clipboard watching, drag & drop, a link-grabber (paste mixed links or **grab all** from a page → dedupe → pattern-expand `file[01-50].zip` → pick), scheduler, Keychain-backed HTTP/FTP auth, cookies/referrer, and system/manual proxy. |
| 🌐 **Built-in browser** | A WebKit browser inside the app (⇧⌘B): visit any site and a live badge lists the video, audio, and files on the page (HLS/DASH manifests, direct files, `attachment` responses) — deduped down to the one thing worth grabbing and titled by the page, with ads, tracking beacons, and stream chunks filtered out (players hidden in shadow DOM still found). IDM-style, it **takes over downloads** the moment a page starts one. Streams open a quality picker so you choose the resolution; logged-in grabs carry your cookies. An optional **ad & tracker blocker** (off by default, in Settings ▸ Browser) drops ad/tracker requests and ad pop-ups on nearly every site via a compiled WebKit content-rule list — with a choice of blocklist: the built-in curated one, or an open-source list (OISD Small, StevenBlack Hosts, Peter Lowe's) downloaded on demand and updatable with one click. Plus a Share Extension and a "Send to CloakDrop" Services item for capture from other apps. |
| 🎬 **Media grabbing** | Detects HLS (`.m3u8`) and DASH (`.mpd`) streams, lists qualities, decrypts AES-128, and pairs each video rendition with its audio track — muxed into a clean, playable file with no re-encode (AVFoundation → `.mp4`/`.m4a`; bundled ffmpeg stream-copies VP9/AV1/Opus → `.mkv`). Subtitle tracks come along as sidecar `.srt` files, and audio-only grabs extract a lossless `.m4a`. |
| 🎥 **Site & video extraction** | Paste a YouTube link into **New Download** — or any of the **~1800 sites** yt-dlp knows — and CloakDrop recognizes the video page, resolves its formats, and grabs them with **its own** segmented engine: the best quality straight away, or a resolution picker when *Ask which quality* is on. yt-dlp only *reads and deciphers*; it never downloads a byte, so pause/resume, persistence, and the sandbox stay CloakDrop's. |
| 🪞 **Multi-source mirrors** | Open a Metalink (`.metalink` / `.meta4`) and CloakDrop spreads segments across its mirrors, fails over the moment one dies or serves corrupt bytes, and verifies the finished file against the Metalink checksum. |
| 🏅 **Download stats** | Local, private lifetime totals — today / this month / all-time — with a playful monthly tier badge that resets each month (Warming Up → ISP's Worst Nightmare). Just counters on your Mac; nothing leaves the device. |
| 🏎️ **Built-in speed test** | Speedometer-style dials measure your connection's real download, upload, idle/loaded latency, and jitter — multi-connection, warm-up-aware, and strictly manual. Cloudflare by default, Ookla optional; reachable from the menu bar. |
| 🌍 **Fully localized** | Every UI string translated into 11 languages (English, Spanish, French, German, Simplified Chinese, Japanese, Korean, Brazilian Portuguese, Russian, Arabic, Hindi). |
| 🪟 **Native to the bone** | SwiftUI + Liquid Glass, full light/dark, VoiceOver + full-keyboard access, a live menu-bar extra, and a Dock icon that shows overall progress at a glance. |

## 🛡️ Privacy first

CloakDrop makes **no** network requests except the ones you start: the URLs you choose to download, the sites you visit in the built-in browser (address-bar search, when enabled, sends the typed query to your chosen engine — DuckDuckGo by default — only when you press Return), a proxy you configure, the built-in **speed test**, which runs only when you press Start against the provider you pick in Settings ▸ Speed Test (Cloudflare by default, Ookla optional) — never on its own — and, if you pick an open-source **ad-block list** in Settings ▸ Browser, that list's server, only when you choose the list or press Update Now, never automatically.

- **On-device only** — no accounts, no analytics, no crash reporting, no phone-home.
- **A browser that forgets** — the built-in browser keeps cookies and site data so logins persist, but records **no browsing history**, and offers a one-click wipe of all site data.
- **Your data stays yours** — download history and settings live in a local SQLite database you can export or delete at any time.
- **Sandboxed** — App Sandbox with security-scoped bookmarks; it only ever touches the folders you point it at.
- **Transparent** — a full privacy policy ships in-app under Settings ▸ Privacy.

## 🧰 Tech stack

| Area | Choice |
|---|---|
| Language | Swift 6 with **strict concurrency** (`complete`) |
| UI | SwiftUI — Liquid Glass throughout, built from the ground up for **macOS 27 Golden Gate**; dropping to AppKit only for the Dock tile & notifications |
| Engine | Actor-based — a `DownloadManager` actor driving one `DownloadTask` actor per transfer |
| Networking | `URLSession` (HTTP Range) + a native **Network.framework FTP/FTPS** client behind one `HTTPClient` protocol seam, both driving segmentation, resume & multi-source (Metalink mirror) spread + failover |
| Persistence | GRDB (SQLite); saved HTTP/FTP & proxy credentials in the **Keychain** |
| Integrity | CryptoKit (checksums) + Security framework (code-signature trust, Provenance Receipt) |
| Media | AVFoundation for passthrough remux/mux (HLS/DASH → clean `.mp4`/`.m4a`) with a bundled ffmpeg fallback for VP9/AV1/Opus (→ `.mkv`), plus poster-frame thumbnails |
| Extraction | A bundled, code-signed **yt-dlp** as a read-only page→formats resolver (YouTube + ~1800 sites); it deciphers URLs while CloakDrop's own engine downloads every byte |
| Capture | A built-in WebKit browser (first-party media sniffing + download takeover), plus Share/Services bridged through a shared App Group inbox |
| Build | XcodeGen (`project.yml` → `.xcodeproj`), SwiftLint |

No third-party Swift dependencies beyond GRDB. Two native command-line tools — **ffmpeg** (muxing) and **yt-dlp** (page extraction) — are bundled as code-signed, sandboxed helper binaries via opt-in build scripts (`apps/macos/scripts/fetch-ffmpeg.sh`, `apps/macos/scripts/fetch-ytdlp.sh`); both only ever *read* or *transform* and add no network egress of their own.

## 🚀 Getting started

Requires **macOS 26+**, **Xcode 26+**, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and an **Apple silicon** Mac.

This repo is a **monorepo**; the native macOS app lives in `apps/macos/` (the brand site is in `apps/site/`).

```bash
brew install xcodegen                  # one-time
git clone https://github.com/cloakyard/cloakdrop.git
cd cloakdrop/apps/macos                # the macOS app lives here
xcodegen generate                      # generate the (git-ignored) Xcode project
open CloakDrop.xcodeproj                # …or build from the command line:
```

```bash
xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop -destination 'platform=macOS' build
```

The `.xcodeproj` is generated and git-ignored — regenerate it any time with `xcodegen generate`. To package a shareable installer DMG (drag-to-Applications, with an install guide), run `scripts/dmg/make-dmg.sh <path/to/CloakDrop.app>` from `apps/macos/`. Released builds are published as [GitHub Release](https://github.com/cloakyard/cloakdrop/releases) assets — the DMG never lives in the repo.

## 🧪 Testing

The engine is UI-agnostic and fully tested in isolation — no GUI required:

```bash
cd apps/macos/Packages/DownloaderCore
swift test
```

**471 tests across 72 suites**, covering the core end-to-end: segmentation/reassembly, **resume across a simulated relaunch**, single-stream fallback, retry-after-drop, dynamic re-splitting, chunked whole-file media grabs (throttle bypass), Metalink spread + mirror failover, checksum verify + sibling discovery, HLS/DASH parsing and AES-128 decryption, native FTP over a loopback server, GCRA bandwidth capping, ZIP extraction (Zip-Slip + bomb rejection), video-page recognition, and a real loopback-HTTP download.

## 🏗️ Project layout

```
cloakdrop/                      # monorepo root
├── apps/
│   ├── macos/                  # The native macOS app (this project)
│   │   ├── App/                # Thin SwiftUI app shell (CloakDrop target)
│   │   │   ├── App/            #   @main entry, AppModel, environment
│   │   │   ├── Features/       #   Sidebar · DownloadList · Inspector · AddDownload · Browser · Settings
│   │   │   ├── Ambient/        #   MenuBarExtra · Dock progress · Notifications
│   │   │   └── Shared/         #   Formatters, icons, shared views
│   │   ├── ShareExtension/     # macOS share-sheet capture
│   │   ├── scripts/            # Opt-in helpers: fetch-ffmpeg.sh · fetch-ytdlp.sh (bundle & sign the native tools) · dmg/ (build the installer DMG) · generate_app_icon.swift (renders the app + About icon from /assets/logo/cloakdrop.svg) · validate_localizations.py
│   │   └── Packages/
│   │       └── DownloaderCore/ # Headless, UI-agnostic, fully unit-tested core
│   │           ├── DownloadModels/       # Sendable value types + HLS/DASH & Metalink parsers + stats, link-grabber, bandwidth-schedule & provenance models
│   │           ├── DownloadPersistence/  # GRDB store behind a protocol
│   │           └── DownloadEngine/       # Actors, segmentation, HTTP + native FTP/FTPS networking, checksums, Keychain credentials, archive extraction, media, yt-dlp resolver
│   └── site/                   # CloakDrop brand site (Astro → Cloudflare Workers, drop.cloakyard.com)
├── assets/                     # Shared brand assets (logo · icons · social card · screenshots)
└── README · LICENSE · CLAUDE.md · CONTRIBUTING · SECURITY · CODE_OF_CONDUCT
```

The brand (`CloakDrop`) lives only at the repo root and the app target; the reusable core is named for the **downloader** domain. See [ARCHITECTURE.md](apps/macos/ARCHITECTURE.md) for the full design.

## 🤝 Contributing

Contributions are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](SECURITY.md).

## 📄 License

Released under the [MIT License](LICENSE). Built by Sumit Sahoo as part of [Cloakyard](https://github.com/cloakyard).
