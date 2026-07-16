# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

CloakDrop is a native, sandboxed macOS Tahoe 26 download manager (IDM-class multi-segment downloads) built as a thin SwiftUI shell over a headless, fully-tested Swift package. See [README.md](README.md) for the product overview and [ARCHITECTURE.md](apps/macos/ARCHITECTURE.md) for the full design.

## Repo layout (monorepo)

This is a **monorepo** with two independent deliverables under `apps/`:

- **`apps/macos/`** — the native macOS app (this document's subject). All the paths below are relative to `apps/macos/` unless noted; run the app commands from there.
- **`apps/site/`** — the CloakDrop brand site (Astro, static), deployed to Cloudflare Workers at `drop.cloakyard.com`. See [apps/site/README.md](apps/site/README.md). It shares nothing with the app build; a Swift change never rebuilds the site and vice-versa (Cloudflare build-watch paths are scoped to `apps/site/*`).

## Commands

The `.xcodeproj` is **generated and git-ignored** — `project.yml` (XcodeGen) is the source of truth. Regenerate after editing `project.yml` or adding/removing source files (run from `apps/macos/`):

```bash
cd apps/macos
xcodegen generate                                                              # requires: brew install xcodegen
xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop -destination 'platform=macOS' build
open CloakDrop.xcodeproj                                                        # or develop/run in Xcode
```

The engine is UI-agnostic and tested in isolation — no GUI, builds in seconds. Prefer this loop for engine work:

```bash
cd apps/macos/Packages/DownloaderCore
swift test                                  # all suites (DownloadModels/Persistence/Engine tests)
swift test --filter EngineIntegrationTests  # one suite (by type name)
swift test --filter multiSegmentCompletes   # one test (by function name; Swift Testing)
```

Lint (config in `apps/macos/.swiftlint.yml`, covers `App/` and `Packages/DownloaderCore/Sources`; run from `apps/macos/`):

```bash
cd apps/macos && swiftlint
```

Package a shareable installer DMG (stylised drag-to-Applications, plus an install guide):

```bash
apps/macos/scripts/dmg/make-dmg.sh <path/to/CloakDrop.app> [output.dmg]   # artwork source: apps/macos/scripts/dmg/background.swift
```

**Environment note (Codex sandbox):** this harness sets `git safe.bareRepository=explicit`, which breaks SwiftPM's git operations. Prefix any command that resolves packages or touches git — `xcodegen generate`, `swift test`, `xcodebuild` — with `GIT_CONFIG_COUNT=0`. If `xcodebuild` fails on an `IDESimulatorFoundation` plugin, run `xcodebuild -runFirstLaunch` once.

## Architecture

**Two layers, one bridge.** `App/` is a thin SwiftUI shell; `Packages/DownloaderCore/` is the headless core. They meet only at `AppModel` (`@MainActor @Observable`), the single object the UI talks to. The core is three layered library targets: `DownloadModels` (Sendable value types, no deps) → consumed by `DownloadPersistence` (GRDB store behind the `DownloadStore` protocol) and `DownloadEngine` (actors, networking, segmentation, checksums). **`DownloadEngine` never imports SwiftUI** — keep download logic out of the app target and UI concerns (colors, SF Symbols, formatting) out of the core.

**Actor concurrency (Swift 6, strict `complete`).** `DownloadManager` (actor) is the single entry point: it owns the catalog of downloads/queues, enforces per-queue concurrency, persists state, and drives one `DownloadTask` actor per active transfer. Inside a task, the parallel segment workers are **nonisolated free functions** (`runSegment`) that report byte deltas back through actor methods, so the authoritative state always mutates serially. Pause/cancel is cooperative — the manager sets a stop reason then cancels the task's enclosing `Task`, and structured cancellation propagates to the segment children.

**Event flow & two-tier UI state.** `DownloadManager` publishes an `AsyncStream<EngineEvent>` via its `events` property; `AppModel.apply(event)` mirrors events into observable state. Status-level changes (`.downloadAdded/Updated/Removed`) update the `downloads` array and the database; high-frequency `.progress` events (~10/sec) flow into a **separate `progress` dictionary** so live speed/ETA never thrash the `downloads` array or hit the DB. `refreshAmbient()` runs after every event to update the Dock progress ring and menu-bar.

**Persistence & resume (the core invariant).** GRDB/SQLite; each `Download` is stored as a JSON payload alongside indexed scalar columns (status/queue/category/order). Bytes stream into a single sparse `*.cdpart` file where each segment owns a contiguous region and its `downloadedBytes` is persisted — so a resume restarts at exactly `segment.start + downloadedBytes`. **Resume must survive force-quit and reboot.** A relaunch integration test enforces this (pause mid-flight → discard the manager → resume a brand-new manager from the same store + part file); extend it whenever you touch the transfer or persistence path.

**Protocol seams for testability.** Networking (`HTTPClient` → `SchemeRoutingHTTPClient` in prod, which dispatches `http(s)` → `URLSessionHTTPClient` and `ftp(s)` → the native `FTPClient`; `MockHTTPClient` with injectable connection drops in tests), storage (`DownloadStore` → `GRDBDownloadStore` / `.inMemory()`), connectivity (`NetworkPathMonitoring` → `NetworkMonitor` / `AlwaysReachableMonitor`), and credentials (`CredentialStoring` → `KeychainCredentialStore` / in-memory) are all behind protocols. Pure math (`SegmentPlanner`, `BandwidthLimiter` — a GCRA virtual-clock limiter, not a per-connection token bucket, so a shared cap holds under concurrency; `BackoffPolicy`, `ChecksumVerifier`, `SpeedSampler`) is I/O-free and unit-tested directly.

## Conventions

- **Brand is scaffolding.** "CloakDrop" / "Cloakyard" appear only at the repo root and the app target; internal modules are named for the *downloader* domain. Name new core code for what it does, not the brand. (The suite is spelled **Cloakyard**, one word, lowercase 'y'.)
- **Adding a feature:** model new persisted state in `DownloadModels`; implement transfer logic in `DownloadEngine` behind the relevant protocol with `MockHTTPClient`/in-memory-store tests; surface it through `AppModel` intents and SwiftUI views. Keep the app target thin.
- **Liquid Glass discipline:** glass only on floating chrome (toolbar/sidebar/inspector), **never on list rows or scrolling content**. **SF Symbols only** for iconography.
- **Sandbox:** App Sandbox + hardened runtime. The default `~/Downloads` is covered by entitlement; user-chosen folders are persisted as security-scoped bookmarks and activated (`SecurityScope`) for the duration of a transfer.
- **Dependencies:** the only third-party Swift dependency is GRDB (persistence). Two native tools — **ffmpeg** (muxing) and **yt-dlp** (page→formats resolver for YouTube + ~1800 sites; a read-only decipher oracle, never a downloader) — are bundled as code-signed, sandboxed `inherit` children via opt-in scripts (`apps/macos/scripts/fetch-ffmpeg.sh`, `apps/macos/scripts/fetch-ytdlp.sh`); both only *read*/*transform* and add no egress — the engine does every byte of downloading. Ask before adding anything else. Prefer system frameworks (e.g. CryptoKit over swift-crypto).
- **Privacy is a hard constraint:** the only network egress is to user-initiated download URLs, the sites the user visits in the built-in browser (plus, if address-bar search is on, the typed query to the chosen search engine — DuckDuckGo default, Google or Bing optional — on Return only; no keystroke/suggestion traffic), a user-configured proxy, the user-started speed test (Settings ▸ Speed Test; Cloudflare by default, Ookla optional — never automatic), and the ad blocker's optional open-source blocklist (Settings ▸ Browser; OISD Small / StevenBlack / Peter Lowe's), fetched only when the user picks a list or presses Update Now — never on a timer or at launch. The browser keeps cookies/site data (so logins persist) but **no browsing history**, and offers a one-click wipe. No telemetry, analytics, accounts, or phone-home.
