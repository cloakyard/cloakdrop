---
name: verify
description: Build, launch, and drive CloakDrop to verify a change end-to-end (GUI via AppleScript + screencapture).
---

# Verifying CloakDrop changes in the running app

## Build & launch (always fresh — never trust an incremental binary)

```bash
killall CloakDrop 2>/dev/null
GIT_CONFIG_COUNT=0 xcodegen generate           # only if project.yml / file list changed
GIT_CONFIG_COUNT=0 xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop \
  -destination 'platform=macOS' -configuration Debug -derivedDataPath build/Verify build
open build/Verify/Build/Products/Debug/CloakDrop.app
```

- **Release does NOT build here**: no signing identities on this machine, and the Release
  entitlements (App Group) require a real cert. Debug (ad-hoc, team-less entitlements) is the
  runnable/shippable config in this environment.
- ARM64 only (never build universal/x86_64).

## Driving the GUI (all TCC permissions work in this harness)

- `osascript` System Events is authorized: menu clicks, `keystroke`, `key code 36` (Return),
  and **coordinate clicks** — `tell process "CloakDrop" to click at {x, y}` — all work.
- `screencapture -x` works (full screen or `-R x,y,w,h`). Window frame via
  `get {position, size} of window N of process "CloakDrop"`. Screenshots are 2x Retina.
- SwiftUI toolbar buttons are NOT enumerable as `buttons of window` — find them in a
  screenshot and use coordinate clicks.
- Open the in-app browser: File ▸ **New Browser Window**, then ⌘L → type URL → Return.
- The media-shelf popover is the down-arrow toolbar button at the browser window's top right
  (badge = candidate count). The quality picker presents as a sheet on the MAIN window ("All").

## Sniffer test page recipe

Serve a local page (`python3 -m http.server 8787` from a scratch dir) with the media shapes to
probe: a real HLS URL (Apple bipbop adv fmp4 master works), a real mp4
(interactive-examples.mdn.mozilla.net flower.mp4), ad-host `<video>` srcs (must NOT appear),
`?bytestart=…&byteend=…` URLs (must NOT appear), a player inside a **closed** shadow root
(must appear), and a `requestMediaKeySystemAccess` probe (must NOT trip the DRM notice).
Downloads land in `~/Downloads` — check the final filename there; delete test files after.

## Gotchas

- This harness sets `git safe.bareRepository=explicit` → prefix xcodegen/xcodebuild/swift with
  `GIT_CONFIG_COUNT=0`.
- Don't pipe xcodebuild through `tail` when you need the verdict — capture to a log file and
  check `$?` (the pipe masks the exit code).
