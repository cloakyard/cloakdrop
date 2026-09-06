---
name: verify
description: Build, launch, and drive CloakDrop to verify a change end-to-end using native UI automation and screenshots.
---

# Verifying CloakDrop changes in the running app

## Build and launch current sources

Start from the repository root. Quit the app instance being verified before opening the newly
built binary; do not leave a stale running instance as the subject of the check.

~~~bash
cd apps/macos
GIT_CONFIG_COUNT=0 xcodegen generate
GIT_CONFIG_COUNT=0 xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/Verify build
open build/Verify/Build/Products/Debug/CloakDrop.app
~~~

Regeneration is required on a fresh checkout and after `project.yml` or source-file-list changes.
Capture the build exit status; do not infer success from the last few log lines.

- Build arm64 only.
- Local verification uses ad-hoc, team-less Debug signing. It does not verify Developer ID
  distribution, notarization or the Release App Group/Share Extension inbox handoff.
- The core suite is independent of the GUI. From the repository root:

~~~bash
cd apps/macos/Packages/DownloaderCore
GIT_CONFIG_COUNT=0 swift test
~~~

## Drive the native GUI

Use the enabled native UI/accessibility tools. Inspect the current accessibility tree before
acting; use screenshot coordinates for controls that are not exposed. When using a computer-use plugin, follow its required UI APIs. AppleScript through System Events
and `screencapture -x` are alternatives only when the active tool policy and permissions allow them.
Do not assume that every SwiftUI toolbar item is enumerable as a direct window button.

- Inspect the app/window identity and frame before taking a screenshot. Retina captures may be
  twice the window's point dimensions.
- Open the browser through File → **New Browser Window** (⇧⌘B), then ⌘L, a URL and Return.
- The browser's down-arrow toolbar item opens the media shelf; its badge reflects candidates.
  The quality picker presents on the main app window.
- Inspect the changed workflow in light and dark, at a compact usable window size, and with
  empty, loading, selected, completed and failed states as relevant.
- Check mouse-to-list keyboard focus, arrow keys, Command-A, search/filter selection clearing,
  sheet cancellation, readable errors and accessible progress values when those paths change.
- For media UI changes, inspect both video and audio-only modes. Confirm that same-language
  tracks remain distinguishable and that an audio-only page has a usable action.

Debug accepts `--verify-dark-appearance` to inspect dark materials without changing the system
appearance. Launch it with `open -n …/CloakDrop.app --args --verify-dark-appearance` after quitting
the previous verification instance. Normal launches and Release builds are unaffected.

For screenshots without transfers or personal history, `--hero-fixture` provides a deterministic,
read-only example catalog. See [the asset guide](../../../assets/README.md) for capture
dimensions and renditions. The fixture does not establish actual throughput or transfer behavior.

## Verify real transfers when behavior changes

Prefer a local fixture server and unique filenames. For transfer/persistence changes, download a
known payload with an explicit checksum, pause during transfer, quit/relaunch, resume, and compare
the output hash to the source. Inspect staging/finalization behavior for the regression under test.
Manager/app relaunch coverage does not prove physical power-loss durability.

For browser detection, serve a scratch page with real, reachable media and exclusion cases:

- A parent HLS/DASH manifest and direct MP4/audio source.
- A player inside a closed shadow root.
- Known ad-host media and byte-range fragment URLs, which must not become downloadable items.
- A `requestMediaKeySystemAccess` capability probe, which must not alone trigger a DRM notice.
- A controlled cookie-protected resource for request-aware preview/capture changes.

Keep the shelf's one-primary-media-item policy in mind when mixing fixtures. Use individual pages
when a candidate's presence needs independent verification. External sample streams are optional;
record their origin and observed result rather than claiming universal site coverage.

Afterward, remove only the test records and files created during verification. Do not clear a
user's history, browser data or lifetime statistics to make screenshots cleaner. Stop fixture
servers and restore window/emulation settings changed for the check. Document any test counters
that remain in lifetime statistics.

## Record evidence

Put shareable audit notes/screenshots under `docs/audits/`, with exact checks, dates and limitations.
Exclude credentials, personal browsing data and unrelated download records from captures.
Use the [September 2026 audit](../../../docs/audits/2026-09-06-overview.md) as an example.

The harness may set `git safe.bareRepository=explicit`; `GIT_CONFIG_COUNT=0` avoids SwiftPM checkout
failures. Do not pipe `xcodebuild` through `tail` when determining success: the pipeline can mask
the build exit code. Save the log and check the command's exit status.
