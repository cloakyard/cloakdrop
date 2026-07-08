# CloakDrop

**A fast, private, multi-segment download manager for macOS — that feels like Apple made it.**

Serious multi-segment download power with the look and feel of a first-party app. No Electron, no web views, no telemetry — everything runs on your Mac and nothing ever phones home.

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey" alt="Platform: macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white" alt="Swift 6.0">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-8A2BE2" alt="SwiftUI · Liquid Glass">
</p>

> Part of the **[Cloakyard](https://github.com/cloakyard)** privacy-first suite, alongside **CloakPDF**, **CloakIMG**, and **CloakResume**.

---

## ✨ What it does

| | |
|---|---|
| 🧵 **Multi-segment downloads** | Splits each file into parallel streams over HTTP Range (configurable, default 8) and reassembles byte-perfectly — with automatic single-stream fallback when a server doesn't support ranges. |
| 🔌 **HTTP, HTTPS & FTP/FTPS** | One engine, many transports — a native FTP/FTPS client (over Network.framework: EPSV/PASV, `REST` resume, implicit TLS for `ftps`) segments and resumes just like HTTP, with no bundled library. |
| ⏯️ **True pause & resume** | Real byte-range resume that survives app relaunch *and* reboot — it never re-downloads a byte. |
| 🔁 **Auto-recovery** | Per-segment retry with exponential backoff + jitter; auto-pauses when the network drops and resumes when it returns. |
| ✅ **Integrity & trust** | MD5 / SHA-1 / SHA-256 verification on completion — from a checksum you supply or auto-discovered from a sibling `.sha256`/`.sha1`/`.md5` — plus a code-signature/notarization trust check on `.app`/`.dmg`/`.pkg`. |
| 🧾 **Provenance Receipt** | Every completed download gets a local, exportable *verified-download record* — sources, TLS, whole-file SHA-256, and checksum + signature verdicts in one trust verdict. No other download manager produces one. |
| 🐢 **Bandwidth control** | Global **and** per-download speed limits (a GCRA throttle that holds the aggregate cap honestly under many concurrent connections), plus optional time-of-day profiles. |
| 🗂️ **Queues, categories & rules** | Per-queue concurrency limits, smart filters, a rule-based routing engine (folder / queue / speed cap / auto-start), duplicate detection, and auto-sorting of finished files into per-type folders. |
| 📦 **Post-processing** | Native ZIP auto-extraction (Zip-Slip + decompression-bomb guarded), a Gatekeeper quarantine flag on saved files, and post-download actions (notify / quit / run a Shortcut). |
| 📋 **Effortless capture** | Clipboard watching, drag & drop, a link-grabber (paste mixed links or **grab all** from a page → dedupe → pattern-expand `file[01-50].zip` → pick), scheduler, Keychain-backed HTTP/FTP auth, cookies/referrer, and system/manual proxy. |
| 🌐 **Built-in browser** | A WebKit browser inside the app (⇧⌘B): visit any site and a live badge lists the video, audio, and files on the page (HLS/DASH manifests, direct files, `attachment` responses) — deduped down to the one thing worth grabbing. IDM-style, it **takes over downloads** the moment a page starts one. Streams open a quality picker so you choose the resolution; logged-in grabs carry your cookies. Plus a Share Extension and a "Send to CloakDrop" Services item for capture from other apps. |
| 🎬 **Media grabbing** | Detects HLS (`.m3u8`) and DASH (`.mpd`) streams, lists qualities, decrypts AES-128, and pairs each video rendition with its audio track — muxed into a clean, playable file with no re-encode (AVFoundation → `.mp4`/`.m4a`; bundled ffmpeg stream-copies VP9/AV1/Opus → `.mkv`). |
| 🎥 **Site & video extraction** | Paste a YouTube page — or any of the **~1800 sites** yt-dlp knows — and CloakDrop resolves the formats and grabs them with **its own** segmented engine. yt-dlp only *reads and deciphers*; it never downloads a byte, so pause/resume, persistence, and the sandbox stay CloakDrop's. |
| 🪞 **Multi-source mirrors** | Open a Metalink (`.metalink` / `.meta4`) and CloakDrop spreads segments across its mirrors, fails over the moment one dies or serves corrupt bytes, and verifies the finished file against the Metalink checksum. |
| 🏅 **Download stats** | Local, private lifetime totals — today / this month / all-time — with a playful monthly tier badge that resets each month (Warming Up → ISP's Worst Nightmare). Just counters on your Mac; nothing leaves the device. |
| 🏎️ **Built-in speed test** | Speedometer-style dials measure your connection's real download, upload, idle/loaded latency, and jitter — multi-connection, warm-up-aware, and strictly manual. Cloudflare by default, Ookla optional; reachable from the menu bar. |
| 🌍 **Fully localized** | Every UI string translated into 11 languages (English, Spanish, French, German, Simplified Chinese, Japanese, Korean, Brazilian Portuguese, Russian, Arabic, Hindi). |
| 🪟 **Native to the bone** | SwiftUI + Liquid Glass, full light/dark, VoiceOver + full-keyboard access, a live menu-bar extra, and a Dock icon that shows overall progress at a glance. |

## 🛡️ Privacy first

CloakDrop makes **no** network requests except to the URLs you choose to download (and, when you configure one, your proxy). The single exception is the built-in **speed test**: it runs only when you press Start, against the provider you pick in Settings ▸ Speed Test (Cloudflare by default, Ookla optional) — never on its own.

- **On-device only** — no accounts, no analytics, no crash reporting, no phone-home.
- **Your data stays yours** — download history and settings live in a local SQLite database you can export or delete at any time.
- **Sandboxed** — App Sandbox with security-scoped bookmarks; it only ever touches the folders you point it at.
- **Transparent** — a full privacy policy ships in-app under Settings ▸ Privacy.

## 🧰 Tech stack

| Area | Choice |
|---|---|
| Language | Swift 6 with **strict concurrency** (`complete`) |
| UI | SwiftUI (macOS Tahoe 26, Liquid Glass), dropping to AppKit only for the Dock tile & notifications |
| Engine | Actor-based — a `DownloadManager` actor driving one `DownloadTask` actor per transfer |
| Networking | `URLSession` (HTTP Range) + a native **Network.framework FTP/FTPS** client behind one `HTTPClient` protocol seam, both driving segmentation, resume & multi-source (Metalink mirror) spread + failover |
| Persistence | GRDB (SQLite); saved HTTP/FTP & proxy credentials in the **Keychain** |
| Integrity | CryptoKit (checksums) + Security framework (code-signature trust, Provenance Receipt) |
| Media | AVFoundation for passthrough remux/mux (HLS/DASH → clean `.mp4`/`.m4a`) with a bundled ffmpeg fallback for VP9/AV1/Opus (→ `.mkv`), plus poster-frame thumbnails |
| Extraction | A bundled, code-signed **yt-dlp** as a read-only page→formats resolver (YouTube + ~1800 sites); it deciphers URLs while CloakDrop's own engine downloads every byte |
| Capture | A built-in WebKit browser (first-party media sniffing + download takeover), plus Share/Services bridged through a shared App Group inbox |
| Build | XcodeGen (`project.yml` → `.xcodeproj`), SwiftLint |

No third-party Swift dependencies beyond GRDB. Two native command-line tools — **ffmpeg** (muxing) and **yt-dlp** (page extraction) — are bundled as code-signed, sandboxed helper binaries via opt-in build scripts (`scripts/fetch-ffmpeg.sh`, `scripts/fetch-ytdlp.sh`); both only ever *read* or *transform* and add no network egress of their own.

## 🚀 Getting started

Requires **macOS Tahoe 26+**, **Xcode 26+**, and [XcodeGen](https://github.com/yonyz/XcodeGen).

```bash
brew install xcodegen                  # one-time
git clone https://github.com/cloakyard/cloakdrop.git
cd cloakdrop
xcodegen generate                      # generate the (git-ignored) Xcode project
open CloakDrop.xcodeproj                # …or build from the command line:
```

```bash
xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop -destination 'platform=macOS' build
```

The `.xcodeproj` is generated and git-ignored — regenerate it any time with `xcodegen generate`. To package a shareable installer DMG (drag-to-Applications, with an install guide), run `scripts/dmg/make-dmg.sh <path/to/CloakDrop.app>`.

## 🧪 Testing

The engine is UI-agnostic and fully tested in isolation — no GUI required:

```bash
cd Packages/DownloaderCore
swift test
```

**377 tests across 64 suites**, covering the core end-to-end: segmentation/reassembly, **resume across a simulated relaunch**, single-stream fallback, retry-after-drop, dynamic re-splitting, Metalink spread + mirror failover, checksum verify + sibling discovery, HLS/DASH parsing and AES-128 decryption, native FTP over a loopback server, GCRA bandwidth capping, ZIP extraction (Zip-Slip + bomb rejection), and a real loopback-HTTP download.

## 🏗️ Project layout

```
cloakdrop/
├── App/                    # Thin SwiftUI app shell (CloakDrop target)
│   ├── App/                #   @main entry, AppModel, environment
│   ├── Features/           #   Sidebar · DownloadList · Inspector · AddDownload · Browser · Settings
│   ├── Ambient/            #   MenuBarExtra · Dock progress · Notifications
│   └── Shared/             #   Formatters, icons, shared views
├── ShareExtension/         # macOS share-sheet capture
├── scripts/                # Opt-in helpers: fetch-ffmpeg.sh · fetch-ytdlp.sh (bundle & sign the native tools) · dmg/ (build the installer DMG)
└── Packages/
    └── DownloaderCore/     # Headless, UI-agnostic, fully unit-tested core
        ├── DownloadModels/       # Sendable value types + HLS/DASH & Metalink parsers + stats, link-grabber, bandwidth-schedule & provenance models
        ├── DownloadPersistence/  # GRDB store behind a protocol
        └── DownloadEngine/       # Actors, segmentation, HTTP + native FTP/FTPS networking, checksums, Keychain credentials, archive extraction, media, yt-dlp resolver
```

The brand (`CloakDrop`) lives only at the repo root and the app target; the reusable core is named for the **downloader** domain. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## 🤝 Contributing & license

Contributions are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](SECURITY.md).

Released under the [MIT License](LICENSE). Built by Sumit Sahoo as part of [Cloakyard](https://github.com/cloakyard).
