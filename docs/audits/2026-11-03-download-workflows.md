# Download workflow implementation — 3 November 2026

All four phases are implemented and locally verified. This records source-tree evidence,
not a published release, notarization result, or universal site compatibility certification.

## Phases

1. Repair ordinary-file downloads with a replacement URL, retaining compatible partial data and requiring an explicit restart otherwise.
2. Finish one download first, hold competing work, and restore normal queue scheduling without resuming manually paused items.
3. Move paused unfinished file/media downloads to another chosen folder, retaining staging and refusing replacement of existing data.
4. Import a bounded media playlist, review item selection, apply one quality preference, and enqueue numbered outputs.

Each phase has focused core regression tests. The existing native app architecture and dependencies
are retained: persisted models in DownloadModels, manager/task logic in DownloadEngine, and thin
AppModel intents with SwiftUI sheets and menus.

## Automated validation

Checks completed on 3 November 2026:

- `GIT_CONFIG_COUNT=0 swift test`: full 670-test suite passes (14 persistence, 341 models,
  315 engine; the opt-in external live-media test is skipped). This includes 20 new workflow
  tests. The external-site matrix was not enabled for this change.
- Repair tests cover retained ranged bytes, changed/weak/missing validators, changed final
  origin/path, failed probes, explicit restart, and credential/mirror reset.
- Priority tests cover cross-queue holding/restoration, manually paused peers, failure, and
  relaunch with resume-on-launch both enabled and disabled.
- Move tests cover both file and media staging, destination collisions including orphan staging,
  inaccessible destinations, persisted new paths and ranged resume after manager relaunch.
- Injected database-save failures verify that repair restart and destination moves preserve
  original staging and catalog state; move copies are rolled back.
- Playlist tests cover bounded enumeration arguments, malformed/unavailable/duplicate entries,
  generic multi-video parent-page URLs, video caps/audio choice, persisted deferred extraction,
  duplicate catalog URLs and completed payloads after manager relaunch.
- `swiftlint --strict`: zero violations.
- `python3 scripts/validate_localizations.py`: 537 source strings across ten translated locales,
  with no missing translations or placeholder mismatch. This is catalog validation, not a
  native-speaker review of every translation.
- Regenerated Xcode project and arm64 Debug `xcodebuild` using `build/Verify`: exit status 0.
  The app used below was freshly launched from that output, with the bundled helpers.
- `git diff --check`: clean.

During verification, the existing media-resume suite caught a filename-allocation regression;
staging-name collision handling was narrowed to destination moves. Native playlist verification
also caught generic embedded videos sharing the parent page URL; preview parsing now preserves
their distinct resource URLs. Both have passing regression coverage.

## Native app and real transfers

The native automation API drove a fresh sandboxed Debug app against a disposable HTTP fixture
on `127.0.0.1:8765`. The primary test payload was 33,554,432 bytes, with an explicit SHA-256:

```
1cbd22e11bc209926b1e050d644779ba4105d7a023109c3b78bb35edf5c7c292
```

1. Started eight-segment `workflow-repair.bin`, paused with saved bytes, quit, and relaunched.
   The fixture expired its original query token. Repairing with a fresh token at the same
   final origin/path reused saved progress.
2. Added `workflow-priority.bin` without starting it, then chose **Finish This First**.
   The banner appeared, the running peer became held/queued, and the urgent 2 MiB file completed.
   The peer then resumed under normal scheduling.
3. Chose **Move Download…** for the running peer and selected another folder. It paused and
   retained about 22 MB of saved data at the new destination. After another app relaunch,
   the destination and progress remained intact.
4. Tried repair with another path advertising the same length and ETag. The UI required an
   explicit restart. Cancel preserved the existing source and bytes.
5. Resumed the moved item. All eight payload requests began at saved offsets; for example,
   the first segment requested bytes `2752512–4194303`. The app reported **Completed · Verified**,
   and an independent filesystem SHA-256 matched the source exactly.
6. Read a local two-video playlist, selected both items, chose **Original quality**, and added it.
   Both completed under `Workflow Lessons` as numbered MKV outputs. `ffprobe` confirmed H.264
   video with one-second duration in both. A second preview showed both entries disabled as
   already added. Audio Only mode hid the video container option and remained usable.

Light and dark appearances were inspected at the existing compact usable main window size
(1097 × 679 points). The 570-point playlist sheet and 480-point repair sheet fit without clipped
actions. Selection, disabled/empty preview actions, sheet cancellation, readable restart errors,
progress, completed state and audio-only controls were checked. Dark appearance used the Debug
launch flag; the system appearance was not changed. No full VoiceOver or physical-device audit
was performed.

Evidence:

- [Paused transfer](images/2026-11-03-workflows/paused-light.png)
- [Priority banner and held peer](images/2026-11-03-workflows/priority-light.png)
- [Moved destination](images/2026-11-03-workflows/moved-light.png)
- [Playlist selection](images/2026-11-03-workflows/playlist-light.png)
- [Completed playlist](images/2026-11-03-workflows/playlist-completed-light.png)
- [Explicit restart decision](images/2026-11-03-workflows/repair-restart-dark.png)
- [Audio-only and duplicate state](images/2026-11-03-workflows/playlist-audio-dark.png)
- [Completed, verified moved file](images/2026-11-03-workflows/completed-dark.png)
- [Independent hashes, resume ranges and output inspection](images/2026-11-03-workflows/transfer-evidence.json)

The four test records and their output files were removed after verification. The four unrelated
catalog records were preserved byte-for-byte. Lifetime statistics were not reset; they include
the roughly 34 MiB of completed file transfers plus the two small media fixtures.

## Policy and website verification

Root `PRIVACY.md`, native Privacy settings and the website revision date now agree on
3 November 2026 and describe user-started playlist metadata resolution. No website layout or
design token changes were made.

- Asset sync, Astro check (19 files; zero errors/warnings), and Astro build passed.
- `node scripts/check-air-design.mjs` passed with 21 surface records.
- Chrome checks at 1440 × 900, 1280 × 720 and 390 × 844 in light/dark showed readable new
  disclosure text, the matching revision date and no horizontal overflow.
- Policy contents → Network activity, Back to CloakDrop, the homepage Download anchor and
  local 404 recovery content were checked. The download action still points at GitHub Releases.
- [Six viewport/theme observations](images/2026-11-03-workflows/privacy-layouts.json),
  [desktop light](images/2026-11-03-workflows/privacy-1440-light.png),
  [laptop dark](images/2026-11-03-workflows/privacy-1280-dark.png),
  [mobile light](images/2026-11-03-workflows/privacy-390-light.png), and
  [mobile dark](images/2026-11-03-workflows/privacy-390-dark.png).

Temporary viewport/theme overrides were reset. This focused content check does not close the
Air inventory's separate physical-touch and spoken-assistive acceptance gates.

## Boundaries

- Repair handles paused/failed ordinary files. Matching strong validator, final origin/path,
  size and range support is required to reuse partial data. Legacy records without the new
  validator origin evidence require restart. A trusted checksum remains the content backstop.
- Move copies data before committing the new location, needs adequate destination space, and
  leaves the item paused. Manager/app relaunch is covered; sudden power loss across filesystems
  and SQLite is not transactional, and interrupted copies can leave unreferenced staging.
- Playlist preview is limited to 100 public entries and requires the optional yt-dlp helper.
  It does not import browser logins. Quality availability is evaluated per item; unsupported
  selections fail individually. An already-resolved expired media plan is not refreshed on resume.
- The run used local fixtures and ad-hoc arm64 Debug signing. It does not verify every external
  service, Release App Group/Share Extension handoff, Developer ID signing, notarization or packaging.
  No release or website deployment was performed.
