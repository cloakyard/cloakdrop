# Contributing to CloakDrop

Thanks for your interest! CloakDrop is part of the **Cloakyard** privacy-first suite. The
guiding principles are non-negotiable: **truly native, minimal, fast, and private** — no
Electron/web-views, no telemetry, no phone-home.

By participating, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md). For the
architecture and where things live, see [ARCHITECTURE.md](ARCHITECTURE.md); for the current
status, see the [README](README.md#-status).

## Prerequisites

- macOS Tahoe 26+
- Xcode 26+
- [XcodeGen](https://github.com/yonyz/XcodeGen): `brew install xcodegen`

## Getting started

```bash
git clone https://github.com/cloakyard/cloakdrop.git
cd cloakdrop
xcodegen generate        # regenerate the (git-ignored) Xcode project from project.yml
open CloakDrop.xcodeproj
```

Run the headless core tests (fast, no GUI):

```bash
cd Packages/DownloaderCore
swift test
```

## Project conventions

- **Swift 6, strict concurrency (`complete`).** No data races, no `@unchecked Sendable` unless
  the invariant is documented and lock-guarded. Prefer actors and structured concurrency.
- **The engine never imports SwiftUI.** All download logic lives in `Packages/DownloaderCore`
  and must be unit-testable in isolation. UI-only concerns (colors, symbols, formatting) live
  in the app target.
- **Protocol boundaries** for networking (`HTTPClient`), storage (`DownloadStore`), and network
  monitoring (`NetworkPathMonitoring`) so each is mockable.
- **Pure logic is pure.** Segmentation, backoff, and throttle math are I/O-free functions with
  direct unit tests — keep them that way.
- **Liquid Glass discipline.** Apply glass only to floating controls and navigation chrome,
  **never to scrolling content or list rows**. Use system materials for layered surfaces.
- **SF Symbols only** for iconography, with hierarchical/multicolor rendering.
- Honor light/dark, Dynamic Type, full keyboard navigation, VoiceOver, and Reduce Motion /
  Reduce Transparency.

## Adding a feature

1. Model it in `DownloadModels` if it needs new persisted state.
2. Implement the logic in `DownloadEngine` behind the relevant protocol, with tests against
   `MockHTTPClient` and/or the in-memory store.
3. Surface it in the app via `AppModel` intents and SwiftUI views.
4. Keep the app target thin — push reusable logic down into the core.

## Tests

Every engine change needs coverage. The bar:

- Pure math → direct unit tests.
- Engine behavior → `MockHTTPClient` integration tests (fast, deterministic). Use injected
  drops to exercise retry/resume.
- Networking path → loopback `URLSessionHTTPClient` tests where it adds real coverage.
- **Resume must survive force-quit and reboot** — if you touch the transfer/persistence path,
  extend the relaunch test.

## Privacy review

Any change that makes a network request, writes outside the sandbox, or adds a dependency must
be called out explicitly in the PR description. Network egress is only ever to user-initiated
download URLs (and, later, the user's configured proxy). When in doubt, ask first.

## Dependencies

Ask before introducing any third-party Swift dependency beyond the persistence layer (GRDB).
Two native command-line tools — **ffmpeg** (muxing) and **yt-dlp** (page extraction) — are bundled
as code-signed, sandboxed helper binaries via opt-in build scripts (`scripts/fetch-ffmpeg.sh`,
`scripts/fetch-ytdlp.sh`); both only *read* or *transform* and must add no network egress of their
own. Prefer system frameworks (e.g. CryptoKit over swift-crypto).
