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
| ⏯️ **True pause & resume** | Real HTTP-Range resume that survives app relaunch *and* reboot — it never re-downloads a byte. |
| 🔁 **Auto-recovery** | Per-segment retry with exponential backoff + jitter; auto-pauses when the network drops and resumes when it returns. |
| ✅ **Integrity checks** | MD5 / SHA-1 / SHA-256 verification on completion — from a checksum you supply, or auto-discovered from a sibling `.sha256`/`.sha1`/`.md5` the server publishes next to the file. |
| 🐢 **Bandwidth control** | Global and per-download speed limits via a token-bucket throttle. |
| 🗂️ **Queues & categories** | Per-queue concurrency limits, smart filters, and auto-sorting of finished files into per-type folders. |
| 📋 **Effortless capture** | Clipboard watching, drag & drop, batch/bulk add with pattern expansion (`file[01-50].zip`), scheduler, HTTP auth, cookies/referrer, and system/direct/manual proxy. |
| 🌐 **Browser & system capture** | A bundled Safari Web Extension, a Chrome/Edge/Brave/Firefox extension over a native-messaging host, plus a Share Extension and a "Send to CloakDrop" Services item — all funnelling through one privacy-preserving on-device inbox. |
| 🎬 **Media grabbing** | Detects HLS (`.m3u8`) and DASH (`.mpd`) streams, lists qualities, downloads the segments over the same engine, decrypts AES-128, and remuxes into a clean, playable `.mp4`/`.m4a` (AVFoundation passthrough — no re-encode). |
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
| Networking | `URLSession` with HTTP Range for segmentation & resume |
| Persistence | GRDB (SQLite) |
| Integrity | CryptoKit |
| Media | AVFoundation for passthrough remux (HLS/DASH → clean `.mp4`/`.m4a`) and poster-frame thumbnails |
| Capture | Safari/WebExtension + native-messaging host + Share/Services, bridged through a shared App Group inbox |
| Build | XcodeGen (`project.yml` → `.xcodeproj`), SwiftLint |

No third-party dependencies beyond GRDB.

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

**143 tests across 26 suites.** Coverage spans segmentation/reassembly correctness, **resume across a simulated relaunch** (for both plain and media grabs), single-stream fallback, retry-after-drop, checksum pass/fail and sibling auto-discovery, pause/resume, scheduling, HLS/DASH manifest parsing, AES-128 segment decryption, AVFoundation remux, and an end-to-end download over a real loopback HTTP server.

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
└── Packages/
    └── DownloaderCore/     # Headless, UI-agnostic, fully unit-tested core
        ├── DownloadModels/       # Sendable value types + HLS/DASH parsers
        ├── DownloadPersistence/  # GRDB store behind a protocol
        └── DownloadEngine/       # Actors, segmentation, networking, checksums, media
```

The brand (`CloakDrop`) lives only at the repo root and the app target; the reusable core is named for the **downloader** domain. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## 🤝 Contributing & license

Contributions are welcome — please read [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md). To report a security issue, see [SECURITY.md](SECURITY.md).

Released under the [MIT License](LICENSE). Built by Sumit Sahoo as part of [Cloakyard](https://github.com/cloakyard).
