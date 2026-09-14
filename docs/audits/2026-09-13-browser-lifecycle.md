# Browser media naming and window lifecycle — September 13, 2026

## Changes

- Direct video/audio captures use the containing page title, including iframe players. Explicit
  attachment names survive later resource sightings. The metadata probe retains captured headers
  and supplies the media extension; long Unicode names reserve space for staging/collision suffixes.
- Main-window presentation restores minimized windows and handles application reopen events.
  Direct browser captures raise the main window and expose metadata resolution progress.
- Native browser-window closure suspends playback and unloads the page, including iframe media.
  Cleanup is idempotent and rejects late navigation/dialog callbacks. Hiding or moving a view
  between windows does not close its session.

## Verification

- arm64 ad-hoc Debug build: passed with warnings treated as errors.
- Core package: 606 tests passed (14 persistence, 327 models, 265 engine).
- Strict SwiftLint: no violations. Localization validation: 494 strings across 10 languages passed.
- Final pre-commit rerun: the full core suite, app build and all three standalone native regressions
  (browser playback, ambient refresh and Dock rendering) passed. Changed and new files were scanned
  again for source-page references; none were found.
- A live direct-video capture completed with its page title and `.mp4` extension. The output hash
  matched the prior payload. The downloads window reopened during transfer without a crash.
  Source URLs, page titles and content screenshots are intentionally excluded from this evidence.
- A loopback iframe fixture reproduced endpoint-based naming before the fix. Afterward it saved
  as `Window Reopen Fixture.mp4`; completed output matched the source SHA-256. Tested closed and
  minimized window recovery, duplicate prompt cancellation, browser closure during transfer,
  application reopening during transfer, and the restored downloads view in dark appearance.
- A standalone regression uses the production `SnifferWebView`, ephemeral WebKit storage and
  generated silent iframe audio. Playback starts, the view moves between windows, the former window
  closes without stopping the player, and the current window closes after detaching the view.
  The retained web view then unloads its document and cannot restart playback from page timers.

Run the playback regression from `apps/macos`:

```sh
swiftc -swift-version 6 -strict-concurrency=complete \
  App/Features/Browser/BrowserWebView.swift scripts/tests/BrowserPlaybackRegression.swift \
  -o /tmp/browser-playback-regression
/tmp/browser-playback-regression
```

Test records and downloaded files were removed; the loopback server was stopped. Existing records,
browser data and lifetime statistics were preserved. Lifetime statistics include verification traffic
from three 268.4 MB loopback transfers and one 638 MB live transfer.

## Limits

The reported app crash did not reproduce, and the available older launch-signing report did not
identify its cause. These checks verify naming, window recovery and playback teardown; they do not
establish that every crash or media source is covered. Release signing, notarization and App Group
handoff were not tested.
