# CloakDrop

**A carefully made, open-source download manager for macOS.**

CloakDrop is for people who care about the details: native SwiftUI controls, resilient transfers,
and video capture that fits into a Mac workflow. A thin app shell sits over an independently tested
Swift engine. Free, MIT-licensed, with no account, telemetry, or CloakDrop service receiving your activity.

**[Website](https://drop.cloakyard.com)** · **[Download the beta](https://github.com/cloakyard/cloakdrop/releases)** · **[Documentation](docs/README.md)** · **[Contributing](CONTRIBUTING.md)**

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%20%C2%B7%20Apple%20silicon-lightgrey" alt="Platform: macOS · Apple silicon">
  <img src="https://img.shields.io/badge/status-beta-2A7B9B" alt="Status: beta">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-8A2BE2" alt="SwiftUI · Liquid Glass">
</p>

<p align="center">
  <picture>
    <source srcset="assets/screenshots/hero-readme.webp" type="image/webp">
    <img src="assets/screenshots/hero-readme.png" alt="CloakDrop on macOS, with the sidebar library, download list, and live segment inspector." width="900">
  </picture>
</p>

Part of **[Cloakyard](https://github.com/cloakyard)**. The screenshot uses a deterministic example
catalog; its displayed speeds are illustrative.

## Download and install

Requires **macOS 26 or later on Apple silicon**. Release builds and bundled helpers are arm64-only.

1. Download the DMG from the [newest GitHub release](https://github.com/cloakyard/cloakdrop/releases) and open it.
2. Drag **CloakDrop** into **Applications**, then open it.
3. If macOS blocks that first launch, and you trust the official download, open **System Settings → Privacy & Security → Open Anyway**, then confirm **Open**.

A small installation note: current beta builds are locally signed but **not notarized**.
Notarization requires a paid Apple Developer Program membership; I’ll consider it if there’s enough
demand. See [Apple’s opening guidance](https://support.apple.com/en-us/102445) and the release notes
for the specific build.

This README describes the **current source**, which may be ahead of the published beta. Each
release’s notes and assets are the source of truth for its features, checksums, and signing status.

## What it does

| Capability | Implementation |
|---|---|
| **Adaptive parallel transfers** | Size-aware automatic planning, a configurable connection budget up to 32, and per-download overrides. Bounded scheduling and tail work-stealing keep useful connections busy. Incorrect HTTP ranges trigger a coherent single-stream restart. |
| **HTTP, HTTPS, FTP and FTPS** | Native transports, including FTP resume probing and implicit TLS for FTPS. Retries use backoff and jitter; connectivity changes can pause and resume configured work. |
| **Pause and resume** | Persisted segment offsets and private staging files support app relaunch. Size, range and available resource validators guard against mixing incompatible remote representations. |
| **Integrity and provenance** | Optional MD5, SHA-1 and SHA-256 verification before ordinary files are published; same-origin checksum discovery; local exportable receipts. Offline code-signature checks are available for recognizable app/DMG code objects, without claiming a notarization verdict. |
| **Mirrors and safe publication** | Metalink mirror spread and failover, source validation, filename sanitization and collision handling. Finalization must never replace an existing file or directory. |
| **Queues and bandwidth** | Per-queue concurrency, global and per-download speed caps, time-of-day profiles, scheduling, categories and routing rules. |
| **Capture from your workflow** | Clipboard watching, drag and drop, Services, a Share Extension, and a link grabber with deduplication and pattern expansion. Remembered credentials use Keychain; request-specific state is retained locally for resume. |
| **Built-in browser** | WebKit with persistent logins, no saved browsing history, and a one-click site-data wipe. Detects manifests, direct media and file downloads, including players in shadow DOM; filters known ad hosts and stream chunks. Optional blocklists are fetched only when selected or updated. |
| **Video and audio grabbing** | HLS/DASH quality selection, supported AES-128 streams, subtitle sidecars and independently downloadable audio renditions. Optional yt-dlp resolves supported video pages and audio-only pages; CloakDrop’s own engine transfers the selected payload. |
| **Local media processing** | AVFoundation passthrough for compatible media, with an optional network-free ffmpeg helper for additional formats such as VP9, AV1 and Opus. No re-encoding. |
| **Useful finishing touches** | Guarded ZIP extraction, download quarantine, completion actions, local statistics, and a speed test that runs only when started by you. |
| **Native macOS UI** | SwiftUI and Liquid Glass, light/dark appearance, keyboard and VoiceOver support, reduced-motion handling, menu-bar and Dock progress, and an interface localized into 11 languages. |

### Current boundaries

Media support depends on the site, login state, region, URL lifetime and bundled extractor version.
DRM-protected formats are excluded. The browser shelf currently represents one primary media item
per page. Continuous live recording, automatic re-resolution of expired media URLs, and separate
authentication headers for every media resource are not implemented.

If a split video requires an external audio track that cannot be resolved, preparation fails rather
than silently choosing silent video. A later muxing failure is a separate limitation: if every
available muxer rejects the downloaded pair, the current finalizer can keep a video-only result.
Subtitle sidecars are best effort.

App proxy settings cover HTTP transfers and speed tests. The browser supports system/manual proxy
selection; native FTP connects directly, and the app does not pass its proxy settings to yt-dlp.
The Share Extension inbox requires an appropriately signed App Group build; the team-less Debug
configuration does not exercise that handoff.

Resume has automated and GUI coverage across manager/app relaunch. That evidence does not establish
physical power-loss durability or compatibility with every FTP/FTPS server. Without a usable
validator or trusted checksum, equal-length remote changes can remain undetected. The
[audit overview](docs/audits/2026-09-06-overview.md) records tested behavior and remaining limits.

## Privacy

There are no analytics, accounts, crash-report uploads, automatic update checks, or phone-home
requests. Network activity is limited to work you initiate or configure: transfers and their
redirects/mirrors/retries; optional same-origin checksum discovery; submitted video-page resolution;
browser pages and subresources; searches submitted on Return; configured proxies; manual speed
tests; and blocklists you explicitly select or update. Scheduled transfers and automatic resume can
continue work configured earlier.

Download records, settings, receipts and statistics stay on your Mac. The browser retains cookies
and site data for logins, but no browsing history. App Sandbox limits filesystem access to the app’s
containers, Downloads and destinations you select. See the [full privacy policy](PRIVACY.md) and
[security policy](SECURITY.md) for storage, authentication and network boundaries.

## Build the app

Requires **macOS 26+**, **Xcode 26+**, an **Apple silicon** Mac and
[XcodeGen](https://github.com/yonaskolb/XcodeGen). The headless Swift 6 package separately declares
macOS 15 as its minimum deployment target.

~~~bash
brew install xcodegen
git clone https://github.com/cloakyard/cloakdrop.git
cd cloakdrop/apps/macos
xcodegen generate
xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/Verify build
open build/Verify/Build/Products/Debug/CloakDrop.app
~~~

`project.yml` is the source of truth; the generated `.xcodeproj` is ignored. Regenerate after
changing project configuration or adding/removing source files. Debug is locally ad-hoc signed
without a developer team. Release signing and App Group capabilities require an appropriate signing
configuration; packaging alone does not notarize the app.

In agent environments that inject `git safe.bareRepository=explicit`, prefix `xcodegen`,
`xcodebuild` and `swift test` with `GIT_CONFIG_COUNT=0` so SwiftPM can resolve packages.

### Optional media helpers

From `apps/macos/`, run these opt-in scripts before rebuilding:

~~~bash
scripts/fetch-ffmpeg.sh
scripts/fetch-ytdlp.sh
~~~

The scripts verify pinned upstream artifacts and stage the helpers for the app’s signing step.
Without ffmpeg, compatible AVFoundation processing remains available. Without yt-dlp, direct media
and manifest downloads still work, while extractor-based page resolution is unavailable.

| Layer | Choice |
|---|---|
| App | SwiftUI, AppKit, WebKit and system accessibility |
| Core | Swift 6 actors, structured concurrency and protocol seams |
| Networking | URLSession and a native Network.framework FTP/FTPS client |
| Persistence | GRDB/SQLite; Keychain for remembered credentials |
| Integrity | CryptoKit and Security framework |
| Media | AVFoundation plus optional [ffmpeg](apps/macos/Vendor/ffmpeg/README.md) |
| Page extraction | Optional [yt-dlp](apps/macos/Vendor/yt-dlp/README.md), used for metadata and media URLs |
| Build | XcodeGen and SwiftLint; the independent website uses Astro |

GRDB is the only third-party Swift dependency. The
[dependency audit](docs/audits/2026-09-06-dependencies.md) records exact versions, upstream sources,
verification and compatibility exceptions. The latest audited yt-dlp release still bundles some
older runtime libraries, including OpenSSL with a newer security patch available. Updating the
extractor does not update every frozen dependency; the audit records the pending runtime rebuild.

To package the Debug build as a drag-to-Applications DMG, from `apps/macos/`:

~~~bash
scripts/dmg/make-dmg.sh build/Verify/Build/Products/Debug/CloakDrop.app
~~~

Release assets belong on [GitHub Releases](https://github.com/cloakyard/cloakdrop/releases), not in
the source repository. Bundled tools retain their own licenses and distribution requirements.

## Testing

From the **repository root**, run the headless suite:

~~~bash
cd apps/macos/Packages/DownloaderCore
swift test
~~~

The **September 6, 2026 audit passed 593 tests across 83 suites**, covering segment scheduling,
relaunch/resume, range and identity validation, retry truncation, cancellation races, credential
scoping, HTTP/FTP loopback transfers, safe publication, checksums, bandwidth limiting, archive
guards, manifest parsing and media extraction. See the [engine audit](docs/audits/2026-09-06-engine.md)
and [video audit](docs/audits/2026-09-06-video.md).

Normal tests use mocks or loopback servers; a cold package resolution may fetch GRDB. To opt into
live-origin smoke tests, supply your own HTTP(S) test files from the package directory:

~~~bash
CLOAKDROP_LIVE_TEST_URLS='https://origin.example/file,https://another.example/file' \
  swift test --filter LiveOriginSmokeTests
~~~

The dated audit also includes an arm64 Debug build, static analysis, lint/localization checks and
native GUI verification of a checksum-matched transfer, pause/relaunch/resume and browser capture.
For the repeatable visual workflow, see the [verification guide](.agents/skills/verify/SKILL.md).

## Repository layout

~~~text
cloakdrop/
├── apps/
│   ├── macos/
│   │   ├── App/                       # Thin SwiftUI shell and AppModel bridge
│   │   ├── ShareExtension/            # Share-sheet capture
│   │   ├── Packages/DownloaderCore/
│   │   │   ├── Sources/
│   │   │   │   ├── DownloadModels/
│   │   │   │   ├── DownloadPersistence/
│   │   │   │   └── DownloadEngine/
│   │   │   └── Tests/
│   │   ├── Vendor/                    # Opt-in helpers and provenance notes
│   │   ├── scripts/                   # Helper fetch, DMG and validation tools
│   │   └── project.yml                # XcodeGen source
│   └── site/                          # Astro site → Cloudflare Workers
├── assets/                            # Shared icons, artwork and screenshots
└── docs/                              # Documentation index and dated audits
~~~

See the [architecture](apps/macos/ARCHITECTURE.md), [website guide](apps/site/README.md),
[asset guide](assets/README.md) and [documentation index](docs/README.md).

## Contributing and license

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md); report vulnerabilities through [SECURITY.md](SECURITY.md).

CloakDrop source is released under the [MIT License](LICENSE). Third-party components retain their
own licenses. Built by Sumit Sahoo as part of [Cloakyard](https://github.com/cloakyard).
