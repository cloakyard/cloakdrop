# Contributing to CloakDrop

CloakDrop is part of **Cloakyard**. Its guiding principles are native macOS interaction, careful
engineering, a small dependency surface and privacy. The app shell is SwiftUI; WebKit is used for
the user-facing browser.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Start with the
[README](README.md#what-it-does), [architecture](apps/macos/ARCHITECTURE.md) and
[documentation index](docs/README.md). The README describes current source, which may be ahead of
the published beta.

## App setup

Requires macOS 26+ on Apple silicon, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)
and SwiftLint. The app and bundled helpers are arm64-only.

~~~bash
brew install xcodegen swiftlint
git clone https://github.com/cloakyard/cloakdrop.git
cd cloakdrop/apps/macos
xcodegen generate
xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath build/Verify build
open build/Verify/Build/Products/Debug/CloakDrop.app
~~~

`project.yml` is authoritative; regenerate the ignored project after configuration or file-list
changes. Debug uses ad-hoc, team-less signing for local verification. It does not validate the
Release App Group/Share Extension handoff, Developer ID distribution or notarization.

In agent environments that set `git safe.bareRepository=explicit`, prefix `xcodegen`,
`xcodebuild` and `swift test` with `GIT_CONFIG_COUNT=0`.

The two optional media helpers have separate setup and provenance guides:
[ffmpeg](apps/macos/Vendor/ffmpeg/README.md) and [yt-dlp](apps/macos/Vendor/yt-dlp/README.md).
Run their fetch scripts from `apps/macos/` before rebuilding to include them.

## Checks

Each block below starts from the **repository root**.

~~~bash
cd apps/macos/Packages/DownloaderCore
swift test
swift test --filter EngineIntegrationTests
~~~

~~~bash
cd apps/macos
swiftlint --strict
python3 scripts/validate_localizations.py
~~~

Normal core tests use mocks and loopback servers; initial package resolution may fetch GRDB.
Live-origin smoke tests are opt-in through `CLOAKDROP_LIVE_TEST_URLS`; use endpoints you select
and follow the [README example](README.md#testing).

For app changes, build and inspect the affected workflow in the running app using the
[verification guide](.agents/skills/verify/SKILL.md). Check light/dark appearance, keyboard focus,
selection, error/empty states, VoiceOver labels and reduced motion where relevant. Use isolated
fixture records and remove only the records/files created for your check.

## Project conventions

- **Swift 6 with strict concurrency.** Prefer actors and structured concurrency. An
  `@unchecked Sendable` conformance needs a documented, enforced invariant.
- **Keep the engine independent of SwiftUI.** Download behavior lives in
  `apps/macos/Packages/DownloaderCore`; colors, symbols, formatting and interaction belong in the app.
- **Preserve protocol seams** for networking, storage, connectivity and credentials so behavior
  remains testable with mocks and in-memory stores.
- **Keep pure logic I/O-free.** Segmentation, backoff and throttle math get direct tests.
- **Use native controls and SF Symbols.** Glass belongs on floating chrome, never scrolling
  content or list rows. Respect system appearance, accessibility and motion preferences.
- **Localize user-facing strings** in the string catalog and validate all supported translations
  and format placeholders.

For a feature, model persisted state in `DownloadModels`, implement reusable behavior in
`DownloadEngine` behind the appropriate protocol, then expose it through `AppModel` intents and
SwiftUI views. Keep the app shell thin.

## Reliability requirements

Add meaningful regression coverage when transfer or persistence behavior changes. Pure math needs
direct tests; engine behavior should use deterministic clients and injected failures. Exercise
the real URLSession/FTP path with loopback tests when transport behavior matters.

- Resume must survive force-quit and reboot. The existing relaunch test covers saved offsets and
  reopening the same store/staging file with a new manager; it is not a physical power-loss test.
  Extend coverage when changing durability or recovery.
- A ranged response must prove the requested interval and compatible resource identity before
  writing. Test malformed ranges, oversized bodies, retries and coherent single-stream fallback.
- Cancellation must retire the correct task even when sessions reuse numeric task IDs.
- Request credentials must remain scoped to their origin across redirects, mirrors and
  authentication challenges; proxy credentials have a separate scope.
- Finalization must never overwrite an existing file or directory. A checksum mismatch must
  prevent publication.
- Media changes should cover parent-manifest resolution, redirects, separate audio requirements,
  hostile input bounds and failure behavior. Do not describe DRM, every site or continuous live
  recording as supported.

See the [dated audit](docs/audits/2026-09-06-overview.md) for observed coverage and open limits.

## Privacy and dependencies

Call out network activity, access outside the sandbox and dependency changes in the PR description.
Allowed network work is limited to configured transfers, redirects, mirrors, retries, schedules,
resume and optional same-origin checksum discovery; metadata resolution for a submitted video
page; browser pages/subresources and searches submitted on Return; configured proxies; manual
speed tests; and blocklists explicitly selected or updated. No telemetry, analytics, accounts or
phone-home. Preserve the boundaries in [PRIVACY.md](PRIVACY.md).

Ask before adding dependencies beyond the existing stack, including new helper-build tooling.
GRDB is the only third-party Swift dependency. Prefer system frameworks such as CryptoKit.
The optional ffmpeg helper processes local media without network support. yt-dlp may resolve
submitted pages and their service endpoints, but CloakDrop’s engine must transfer the selected
media payload.

When updating existing dependencies, verify official versions, compatibility and provenance;
update the appropriate lockfile/pinned hashes and vendor guide. The core `Package.resolved` and
site `package-lock.json` are tracked; generated Xcode workspace locks are not. Check the entire
bundled runtime, not only the helper’s version banner. Preserve upstream license notices and
corresponding-source requirements when distributing binaries. Record exceptions in a dated audit.

## Website and documentation

The independent Astro site lives in `apps/site/`. From the repository root:

~~~bash
cd apps/site
npm ci
npm run check
npm run build
~~~

Use Node 22.12.0 or later. Follow the [site guide](apps/site/README.md) for preview, responsive and
accessibility checks, and Cloudflare configuration. Edit shared images in `assets/`; builds copy
them into the site. The privacy page renders the root `PRIVACY.md`.

Keep the README, architecture, capability inventory, privacy/security policies, affected vendor
guides and website copy aligned with behavior. Update the policy page’s displayed date when its
source policy changes, and sync the native Privacy settings page and its localized text/date.
Update installation guidance in the README, website and DMG together.
Describe source capabilities separately from shipped release contents, and record actual test
evidence without promising universal compatibility or fault tolerance.

Before submitting, run `git diff --check`, check changed document links and command working
directories, and summarize the change, relevant verification and remaining limits. Do not commit
generated projects, helper binaries, DMGs or build output.
