# Dependency verification - 7 October 2026

## Updates and provenance

- Website: Astro 7.3.6, Wrangler 4.148.0, fast-uri 3.1.8 and sharp 0.35.5.
  `npm outdated` reports only TypeScript: retained at 6.0.3 because the latest
  `@astrojs/check` 0.9.10 declares `^5.0.0 || ^6.0.0`, not TypeScript 7 support.
- GRDB 7.11.1 remains the latest published stable release. No Swift dependency
  was added or replaced.
- FFmpeg updated from 9.0.1 to 9.0.2. Its source archive's detached signature
  verified against the release key published on FFmpeg's official download page:
  `FCF986EA15E6E293A5644F10B4322F04D67658D8`.
  SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
  Built with the existing LGPL-only, arm64, remux-only flags. Signature,
  architecture, reported version and system-only linkage checks passed. Its
  only input/output protocols are `file`, `pipe` and `fd`; no network protocols.
- yt-dlp 2026.08.19 remains the latest official stable bundle. Its release asset
  digest still matches the existing pin. The installed helper reports that version.

## Approved frozen-runtime exception

The maintainer explicitly chose to retain the complete official yt-dlp bundle
and document its older Python/OpenSSL and other frozen dependencies, rather
than introduce a custom helper build. The runtime inventory and limitations in
the [September dependency audit](2026-09-06-dependencies.md) still apply.
No frozen runtime files were individually replaced. **This is not an assertion
that every library inside yt-dlp is current or free of known vulnerabilities.**

## Verification

- `GIT_CONFIG_COUNT=0 swift test`: 271 tests in 41 suites passed.
- Repeated the full suite with `FFMPEG_PATH` pointing to the newly built
  `apps/macos/Vendor/ffmpeg/ffmpeg`: 271 tests passed, including real H.264/AAC
  mux and remux tests. The test helper now accepts this explicit path so the
  vendored binary can be tested instead of silently using Homebrew FFmpeg.
- Fixed an existing stale error-message assertion: the invalid-bookmark test
  now expects the current "restore access to the original download folder"
  guidance, retaining the failure-status and no-file-written assertions.
- `swiftlint --strict`: 0 violations in 174 files.
- Localization validator: 494 strings across 10 languages passed.
- Regenerated Xcode project; arm64 Debug build in `build/Verify` passed.
- `codesign --verify --deep --strict` on the built app passed.
- Quit the previous app, launched the exact `build/Verify` executable, inspected
  the empty library, opened New Download and cancelled it successfully. No
  download records, user files or settings were modified by the GUI check.
- Website `npm run check`: 0 errors, warnings or hints across 19 files.
- Website `npm run build`: all 3 static routes built.
- Website `npm audit`: 0 vulnerabilities after the transitive fixes.

These are local ad-hoc Debug results, not Developer ID/notarization or Release
Share Extension/App Group verification. The GUI smoke did not exercise an
external video site or new live transfers; core transfer and mux behavior was
exercised by the automated suite. Existing PR website/documentation changes
are retained separately from this dependency update.
