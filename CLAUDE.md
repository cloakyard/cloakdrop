# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

CloakDrop is a native, sandboxed macOS Tahoe 26 download manager (IDM-class multi-segment downloads) built as a thin SwiftUI shell over a headless, fully-tested Swift package. See [README.md](README.md) for the product overview and [ARCHITECTURE.md](ARCHITECTURE.md) for the full design.

## Commands

The `.xcodeproj` is **generated and git-ignored** — `project.yml` (XcodeGen) is the source of truth. Regenerate after editing `project.yml` or adding/removing source files:

```bash
xcodegen generate                                                              # requires: brew install xcodegen
xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop -destination 'platform=macOS' build
open CloakDrop.xcodeproj                                                        # or develop/run in Xcode
```

The engine is UI-agnostic and tested in isolation — no GUI, builds in seconds. Prefer this loop for engine work:

```bash
cd Packages/DownloaderCore
swift test                                  # all suites (DownloadModels/Persistence/Engine tests)
swift test --filter EngineIntegrationTests  # one suite (by type name)
swift test --filter multiSegmentCompletes   # one test (by function name; Swift Testing)
```

Lint (config in `.swiftlint.yml`, covers `App/` and `Packages/DownloaderCore/Sources`):

```bash
swiftlint
```

**Environment note (Claude Code sandbox):** this harness sets `git safe.bareRepository=explicit`, which breaks SwiftPM's git operations. Prefix any command that resolves packages or touches git — `xcodegen generate`, `swift test`, `xcodebuild` — with `GIT_CONFIG_COUNT=0`. If `xcodebuild` fails on an `IDESimulatorFoundation` plugin, run `xcodebuild -runFirstLaunch` once.

## Architecture

**Two layers, one bridge.** `App/` is a thin SwiftUI shell; `Packages/DownloaderCore/` is the headless core. They meet only at `AppModel` (`@MainActor @Observable`), the single object the UI talks to. The core is three layered library targets: `DownloadModels` (Sendable value types, no deps) → consumed by `DownloadPersistence` (GRDB store behind the `DownloadStore` protocol) and `DownloadEngine` (actors, networking, segmentation, checksums). **`DownloadEngine` never imports SwiftUI** — keep download logic out of the app target and UI concerns (colors, SF Symbols, formatting) out of the core.

**Actor concurrency (Swift 6, strict `complete`).** `DownloadManager` (actor) is the single entry point: it owns the catalog of downloads/queues, enforces per-queue concurrency, persists state, and drives one `DownloadTask` actor per active transfer. Inside a task, the parallel segment workers are **nonisolated free functions** (`runSegment`) that report byte deltas back through actor methods, so the authoritative state always mutates serially. Pause/cancel is cooperative — the manager sets a stop reason then cancels the task's enclosing `Task`, and structured cancellation propagates to the segment children.

**Event flow & two-tier UI state.** `DownloadManager` publishes an `AsyncStream<EngineEvent>` via its `events` property; `AppModel.apply(event)` mirrors events into observable state. Status-level changes (`.downloadAdded/Updated/Removed`) update the `downloads` array and the database; high-frequency `.progress` events (~10/sec) flow into a **separate `progress` dictionary** so live speed/ETA never thrash the `downloads` array or hit the DB. `refreshAmbient()` runs after every event to update the Dock progress ring and menu-bar.

**Persistence & resume (the core invariant).** GRDB/SQLite; each `Download` is stored as a JSON payload alongside indexed scalar columns (status/queue/category/order). Bytes stream into a single sparse `*.cloakpart` file where each segment owns a contiguous region and its `downloadedBytes` is persisted — so a resume restarts at exactly `segment.start + downloadedBytes`. **Resume must survive force-quit and reboot.** A relaunch integration test enforces this (pause mid-flight → discard the manager → resume a brand-new manager from the same store + part file); extend it whenever you touch the transfer or persistence path.

**Protocol seams for testability.** Networking (`HTTPClient` → `URLSessionHTTPClient` prod / `MockHTTPClient` with injectable connection drops), storage (`DownloadStore` → `GRDBDownloadStore` / `.inMemory()`), and connectivity (`NetworkPathMonitoring` → `NetworkMonitor` / `AlwaysReachableMonitor`) are all behind protocols. Pure math (`SegmentPlanner`, `BandwidthLimiter`, `BackoffPolicy`, `ChecksumVerifier`, `SpeedSampler`) is I/O-free and unit-tested directly.

## Conventions

- **Brand is scaffolding.** "CloakDrop" / "Cloakyard" appear only at the repo root and the app target; internal modules are named for the *downloader* domain. Name new core code for what it does, not the brand. (The suite is spelled **Cloakyard**, one word, lowercase 'y'.)
- **Adding a feature:** model new persisted state in `DownloadModels`; implement transfer logic in `DownloadEngine` behind the relevant protocol with `MockHTTPClient`/in-memory-store tests; surface it through `AppModel` intents and SwiftUI views. Keep the app target thin.
- **Liquid Glass discipline:** glass only on floating chrome (toolbar/sidebar/inspector), **never on list rows or scrolling content**. **SF Symbols only** for iconography.
- **Sandbox:** App Sandbox + hardened runtime. The default `~/Downloads` is covered by entitlement; user-chosen folders are persisted as security-scoped bookmarks and activated (`SecurityScope`) for the duration of a transfer.
- **Dependencies:** ask before adding any beyond GRDB (persistence) and, possibly later, ffmpeg. Prefer system frameworks (e.g. CryptoKit over swift-crypto).
- **Privacy is a hard constraint:** the only network egress is to user-initiated download URLs (and, later, a user-configured proxy). No telemetry, analytics, accounts, or phone-home.
