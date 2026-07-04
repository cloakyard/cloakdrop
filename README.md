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
| 🧾 **Provenance Receipt** | Every completed download gets a local, exportable *verified-download record* — source & mirrors, transport/TLS, whole-file SHA-256, checksum + signature verdicts, rolled into one trust verdict. No other download manager produces one. |
| 🐢 **Bandwidth control** | Global **and** per-download speed limits via a virtual-clock (GCRA) throttle that holds the aggregate cap honestly under many concurrent connections, plus optional time-of-day speed profiles. |
| 🗂️ **Queues, categories & rules** | Per-queue concurrency limits, smart filters, a smart-rule routing engine (folder / queue / speed cap / auto-start), duplicate detection, and auto-sorting of finished files into per-type folders. |
| 📦 **Post-processing** | Native ZIP auto-extraction (Zip-Slip + decompression-bomb guarded), a Gatekeeper quarantine flag on saved files, and post-download actions (notify / quit / run a Shortcut). |
| 📋 **Effortless capture** | Clipboard watching, drag & drop, a link-grabber (paste a wall of mixed links or **grab all** from a page URL → dedupe → pattern-expand `file[01-50].zip` → pick), scheduler, HTTP/FTP auth with a Keychain-backed saved-credential store, cookies/referrer, and system/direct/manual proxy. |
| 🌐 **Browser & system capture** | A bundled Safari Web Extension, a Chrome/Edge/Brave/Firefox extension over a native-messaging host, plus a Share Extension and a "Send to CloakDrop" Services item — all funnelling through one privacy-preserving on-device inbox. |
| 🎬 **Media grabbing** | Detects HLS (`.m3u8`) and DASH (`.mpd`) streams, lists qualities, downloads the segments over the same engine, decrypts AES-128, and always pairs a video rendition with its separate audio track so a grab is never silent — muxing and remuxing into a clean, playable file (AVFoundation passthrough → `.mp4`/`.m4a`; a bundled ffmpeg stream-copies VP9/AV1/Opus → `.mkv`; no re-encode either way). |
| 🎥 **Site & video extraction** | Paste a YouTube page — or any of the **~1800 sites** yt-dlp knows — and CloakDrop resolves the real video/audio formats, lists the qualities, and grabs them with **its own** segmented engine. yt-dlp only *reads and deciphers* (it never downloads a byte), so pause/resume, persistence, the sandbox, and no-re-encode muxing all stay CloakDrop's. |
| 🪞 **Multi-source mirrors** | Open a Metalink (`.metalink` / `.meta4`) and CloakDrop spreads segments across its mirrors for parallel throughput, fails over to a live mirror the moment one dies, throttles, or serves corrupt bytes, and verifies the finished file against the Metalink's whole-file checksum. |
| 🏅 **Download stats** | Local, private lifetime totals — today / this month / all-time — with a playful monthly tier badge that resets each month (Warming Up → ISP's Worst Nightmare). Just counters on your Mac; nothing leaves the device. |
| 🌍 **Fully localized** | Every UI string translated into 11 languages (English, Spanish, French, German, Simplified Chinese, Japanese, Korean, Brazilian Portuguese, Russian, Arabic, Hindi). |
| 🪟 **Native to the bone** | SwiftUI + Liquid Glass, full light/dark, VoiceOver + full-keyboard access, a live menu-bar extra, and a Dock icon that shows overall progress at a glance. |

## 🛡️ Privacy first

CloakDrop makes **no** network requests except to the URLs you choose to download (and, when you configure one, your proxy).

- **On-device only** — no accounts, no analytics, no crash reporting, no phone-home.
- **Your data stays yours** — download history and settings live in a local SQLite database you can export or delete at any time.
- **Sandboxed** — App Sandbox with security-scoped bookmarks; it only ever touches the folders you point it at.

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
| Capture | Safari/WebExtension + native-messaging host + Share/Services, bridged through a shared App Group inbox |
| Build | XcodeGen (`project.yml` → `.xcodeproj`), SwiftLint |

No third-party Swift dependencies beyond GRDB. Two native command-line tools — **ffmpeg** (muxing) and **yt-dlp** (page extraction) — are bundled as code-signed, sandboxed helper binaries via opt-in build scripts (`scripts/fetch-ffmpeg.sh`, `scripts/fetch-ytdlp.sh`); both only ever *read* or *transform* and add no network egress of their own.

## 📊 Status

**Active development.** The headless engine is feature-complete and fully tested (**312 tests across 55 suites**), and the app is functional end-to-end — multi-segment HTTP/FTP transfers, resume across relaunch, media/site grabbing, multi-source mirrors, the link-grabber, archive extraction, Provenance Receipts, browser capture, and full localization all work today. It targets **macOS Tahoe 26** and builds from source; there is no packaged/notarized release yet. Expect rough edges and API churn while it firms up toward a first release.

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

The `.xcodeproj` is generated and git-ignored — regenerate it any time with `xcodegen generate`.

## 🧪 Testing

The engine is UI-agnostic and fully tested in isolation — no GUI required:

```bash
cd Packages/DownloaderCore
swift test
```

**312 tests across 55 suites.** Coverage spans segmentation/reassembly correctness, **resume across a simulated relaunch** (for both plain and media grabs), single-stream fallback, retry-after-drop, dynamic segment re-splitting (work-stealing), multi-source Metalink spread + mirror failover on dead/corrupt sources, checksum pass/fail and sibling auto-discovery, pause/resume, scheduling, HLS/DASH manifest parsing, AES-128 segment decryption, AVFoundation remux, yt-dlp JSON parsing/format mapping, per-day stat byte-buckets, native FTP multi-segment transfer over a loopback FTP server, GCRA bandwidth-cap-under-concurrency, ZIP extraction (Zip-Slip + decompression-bomb rejection), page link extraction, Provenance Receipt generation, and an end-to-end download over a real loopback HTTP server.

## 🏗️ Project layout

```
cloakdrop/
├── App/                    # Thin SwiftUI app shell (CloakDrop target)
│   ├── App/                #   @main entry, AppModel, environment
│   ├── Features/           #   Sidebar · DownloadList · Inspector · AddDownload · Settings
│   ├── Ambient/            #   MenuBarExtra · Dock progress · Notifications
│   └── Shared/             #   Formatters, icons, shared views
├── SafariExtension/        # Bundled Safari Web Extension (App-Store-friendly capture)
├── BrowserExtension/       # MV3 extension for Chrome · Edge · Brave · Firefox
├── NativeMessagingHost/    # stdio host bridging those browsers to the app
├── ShareExtension/         # macOS share-sheet capture
├── scripts/                # Opt-in build helpers: fetch-ffmpeg.sh · fetch-ytdlp.sh (bundle & sign the native tools)
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
