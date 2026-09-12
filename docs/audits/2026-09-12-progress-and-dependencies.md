# Dock progress, visual and dependency audit — 12 September 2026

## Fixed behavior

The Dock percentage is now the arithmetic mean of the completion fractions of downloads whose
status is `downloading`. For example, a 5 MiB file at 20% and a 20 MiB file at 80% produce **50%**,
regardless of their sizes. Queued, paused, failed, canceled, scheduled and completed records do
not contribute. The badge still counts currently transferring downloads.

The previous calculation divided combined downloaded bytes by persisted file sizes. Besides
weighting large files more heavily, it substituted bytes already received for an unknown total,
which could show a media transfer as 100% complete. The new pure model helper uses live byte totals
or media segment completion, falling back to persisted completion only before a live snapshot
exists. If any active transfer has unknown completion, the combined percentage is indeterminate:
the normal icon and active count remain, without inventing a percentage. Row fractions follow the
same rule for live snapshots.

Progress refreshes retain the existing 333 ms interval and now deliver the final coalesced tick,
even if no further event arrives. Immediate status changes cancel a pending refresh. The Dock
renderer explicitly sizes and invalidates its view, rejects non-finite input, clears progress
when the active count reaches zero, and uses the same rounding for redraw decisions and its label.

## Verification

- Complete Swift package: **600 tests, 84 suites passed** (321 model, 14 persistence, 265 engine).
  Seven new model regressions cover unequal sizes, changing live totals, mixed media/file progress,
  unknown sizes, stale persisted totals, inactive states and extreme byte counts.
- A standalone AppKit harness exercises the production Dock renderer: positive tile dimensions,
  rounding across 49.49% → 49.51%, redraw coalescing, badge changes, indeterminate → known
  transitions, NaN/infinity handling, and clearing when no downloads are active.
- A standalone concurrency harness checks the production refresh throttle: a burst delivers its
  final value without another event, and a status refresh cancels pending work.
- Regenerated Xcode project; arm64 ad-hoc Debug build, strict SwiftLint, all **494 strings across
  ten translated locales**, and deep/strict app signature verification passed.
- Clean site installation, complete npm tree validation, Astro check (20 files; zero diagnostics),
  production build (three pages) and npm audit passed. The final npm graph has **zero reported
  vulnerabilities** on this date. No site deployment was performed.

From `apps/macos/`, the UI-only regression commands are:

```sh
swiftc App/Ambient/DockProgressController.swift scripts/tests/DockProgressRegression.swift -o /tmp/dock-regression
/tmp/dock-regression build/Verify/Build/Products/Debug/CloakDrop.app/Contents/Resources/AppIcon.icns
swiftc App/Ambient/AmbientRefreshThrottle.swift scripts/tests/AmbientRefreshRegression.swift -o /tmp/ambient-regression
/tmp/ambient-regression
```

### Running app and visual evidence

A loopback server supplied two real, deliberately different-sized downloads, stopping at 20% and
80%. Both transfers were visible together; inspector accessibility values confirmed those
percentages. Pause, quit/relaunch and resume were exercised. These endpoints intentionally did
not support ranges, so resume restarted their streams. Both completed with matching independent
hashes; the small download additionally passed the app's explicitly configured SHA-256 check.
This is not new evidence of ranged resume or physical power-loss durability.

```text
audit-0912-small.bin: 5,242,880 bytes
SHA-256: 2e7cab6314e9614b6f2da12630661c3038e5592025f6534ba5823c3b340a1cb6

audit-0912-large.bin: 20,971,520 bytes
SHA-256: 3568217a72eed5450d704907de96e14c75cc1b18661f38e0c9f458e462b38def
```

The native window was inspected in light and Debug-forced dark appearance at approximately
1097 × 679 points, including concurrent transfers, selection/inspector changes, paused and
completed rows, a deliberate HTTP 404, and empty search results. Command-A selected only the
three filtered audit records, and cleanup cleared selection. Text, icons, progress bars and
selection contrast were readable; no additional layout change was required in these states.
The window could not be reduced further with the attempted native corner drag; narrower sizes
and all locales were not newly certified.

- [Production Dock renderer at 50%](images/2026-09-12-dock-average.png).
- [Light paused state](images/2026-09-12-light-paused.png).
- [Dark concurrent transfers](images/2026-09-12-dark-concurrent.png).
- [Dark completed, verified transfer](images/2026-09-12-dark-completed.png).
- [Light failure details](images/2026-09-12-light-failure.png).
- [Empty filtered catalog after cleanup](images/2026-09-12-light-empty.png).

The Dock image is rendered from the actual production `NSView` through the AppKit regression
harness. The macOS Dock accessibility surface timed out, so this is not a capture of the running
Dock process or its system-drawn badge. Arithmetic, view rendering, badge state and refresh
scheduling were verified separately. Release signing, notarization and Release Share Extension
handoff were not verified by this Debug build.

Only the three audit-created records were removed. Completed fixture files were moved to
`/tmp/cloakdrop-0912-fixture/completed/`, and the loopback server was stopped. The app was returned
to normal appearance with its search cleared. The two completed test transfers can remain in
lifetime statistics (25 MiB); unrelated records, files, browser data and statistics were preserved.
Session logs are `/tmp/cloakdrop-0912-*.log` and `/tmp/cloakdrop-0912-npm-audit.json`.

## Dependency updates

Current releases were checked against upstream GitHub release APIs, official project download
pages and npm/PyPI registries. No new third-party dependency was introduced.

| Direct component | Current result | Source |
| --- | --- | --- |
| GRDB.swift | 7.11.1, already current | [Official release](https://github.com/groue/GRDB.swift/releases/tag/v7.11.1) |
| FFmpeg | 9.0.1, already current; installed binary version checked | [Official download page](https://ffmpeg.org/download.html) |
| yt-dlp | 2026.08.19, already latest official stable | [Official release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19) |
| Astro | 7.3.2, already current | [npm](https://registry.npmjs.org/astro/latest) |
| @astrojs/sitemap | 3.7.4, already current | [npm](https://registry.npmjs.org/@astrojs%2Fsitemap/latest) |
| @astrojs/check | 0.9.10, already current | [npm](https://registry.npmjs.org/@astrojs%2Fcheck/latest) |
| TypeScript | 6.0.3, latest supported by Astro Check's `^5.0.0 \|\| ^6.0.0` peer range; 7.0.2 remains incompatible | [npm metadata](https://registry.npmjs.org/@astrojs%2Fcheck/latest) |
| Wrangler | **4.130.0 → 4.131.1** | [npm](https://registry.npmjs.org/wrangler/latest) |

Compatible lockfile updates also include Vite 8.2.2 → 8.3.0, Miniflare
5.20260908.0-alpha → 5.20260911.0-alpha (selected by stable Wrangler), workerd and its five
platform packages 1.20260908.1 → 1.20260911.1, @napi-rs/wasm-runtime 1.2.3 → 1.2.4,
magicast 0.5.4 → 0.5.5, nanoid 3.3.18 → 3.3.19, yaml 2.9.0 → 2.9.1 and zod 4.6.1 → 4.6.2.
The package manifest's Wrangler minimum and workerd script allowlist were advanced together.
Existing compatible overrides remain; incompatible transitive major versions were not forced.

### Remaining runtime update — requires new build dependencies

**Not every bundled library is current.** The installed yt-dlp helper was run with local-only
version/verbose diagnostics and no submitted page URL. It still reports Python **3.14.6**, OpenSSL
**3.5.7**, SQLite **3.50.4**, curl-cffi **0.16.0** and websockets **17.0.1**. The latest official
stable and nightly release tags remain unchanged from the previous audit. Re-downloading that
stable archive cannot update these embedded components.

The [previous runtime rebuild proposal](2026-09-06-dependencies.md#proposed-custom-runtime-awaiting-dependency-approval)
still applies. Current targets are Python **3.14.7**, OpenSSL **3.5.8 LTS** (a security patch),
SQLite **3.53.4**, curl-cffi **0.16.3**, websockets **17.1**, charset-normalizer **3.5.1** and
idna **3.19**. Sources: [Python](https://www.python.org/downloads/),
[OpenSSL](https://openssl-library.org/source/), [SQLite](https://sqlite.org/download.html),
[curl-cffi](https://pypi.org/pypi/curl-cffi/json), [websockets](https://pypi.org/pypi/websockets/json),
[charset-normalizer](https://pypi.org/pypi/charset-normalizer/json) and [idna](https://pypi.org/pypi/idna/json).

The concrete next step is an isolated build of the existing yt-dlp source into its current arm64
onedir layout, using pinned **PyInstaller 6.22.2** and **pyinstaller-hooks-contrib 2026.7** plus their
required build support packages. These are new project-managed build dependencies, unlike the
existing libraries being updated. [PyInstaller](https://pypi.org/pypi/pyinstaller/json) and
[hooks](https://pypi.org/pypi/pyinstaller-hooks-contrib/json) versions were checked on this audit date.
Before replacing the current helper, that candidate needs source/wheel hashes, a full frozen
runtime inventory, nested signature and linkage checks, and sandboxed metadata extraction,
cancellation, cookie and failure tests as laid out in the proposal.

Repository authorization boundary: [`AGENTS.md`](../../AGENTS.md), Dependencies, says **“Ask before
adding anything else.”** No custom build toolchain has been installed or added to project
manifests in this change. Approval for those new build dependencies is still needed; the current
runtime gap is not being reported as resolved.

## Full verification rerun

At the user's request, the complete checks were rerun against the final working tree on
12 September 2026. All commands completed successfully:

| Check | Result |
| --- | --- |
| Full Swift package | 600 tests across 84 suites passed: 321 models, 14 persistence, 265 engine. |
| Real ffmpeg tests | Both H.264/AAC mux and real-file remux tests ran and passed. |
| Dock renderer and ambient throttle | Both production-source regression harnesses compiled in Swift 6 with complete concurrency checking and warnings treated as errors, then passed. |
| Native app | Regenerated project; arm64 Debug build and static analysis passed without compiler/analyzer warnings or errors. Deep/strict signature verification passed. |
| Source checks | Strict SwiftLint, 494 strings × ten translations, vendor/DMG shell syntax, shared asset script syntax and diff whitespace checks passed. |
| Site | Clean npm install, complete dependency tree validation, Astro check, production build and Wrangler deployment dry run passed. No deployment occurred. |
| npm audit | Zero reported vulnerabilities. |

A follow-up review of the aggregation, live-state precedence, Dock clearing/rounding and deferred
refresh cancellation found no new regression. No production changes were needed during this
rerun. The opt-in public-origin smoke entry point had no URLs configured; external-site behavior
was not retested. The existing yt-dlp runtime update gap and Debug/Release verification limits
above remain unchanged.

Rerun logs are session-local at `/tmp/cloakdrop-full-rerun-*.log`, with the vulnerability report
at `/tmp/cloakdrop-full-rerun-npm-audit.json`.
