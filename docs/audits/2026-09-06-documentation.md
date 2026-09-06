# CloakDrop documentation audit — 6 September 2026

Reviewed all tracked Markdown/text documentation, the new vendor guide and dated audit reports
against the current implementation. The documentation index now separates product guidance,
development/distribution instructions and dated evidence.

## Coverage

| Document | Review outcome |
| --- | --- |
| [Root README](../../README.md) | Clear open-source positioning, GitHub installation steps and a small notarization note; current capabilities, limitations, build/helper commands, test evidence and a corrected source tree. |
| [Contributing](../../CONTRIBUTING.md) | Consistent working directories, Debug signing boundaries, localization/lint checks, dependency provenance, site checks and documentation maintenance. |
| [Architecture](../../apps/macos/ARCHITECTURE.md) | Current transfer, identity, authentication, FTP, media and durability contracts; observed coverage distinguished from requirements. |
| [Capability inventory](../../apps/macos/COMPETITIVE.md) | Implemented behavior and remaining work separated; no unsupported competitor comparison. |
| [Privacy](../../PRIVACY.md) | Local request state, temporary browser cookie jars, origin scoping, exact proxy coverage and helper behavior; revision date synchronized with the website. |
| [Native privacy page](../../apps/macos/App/Features/Settings/PrivacySettingsView.swift) | Matching revision date, storage/proxy/helper boundaries and licensing copy, with translated text and a link to the source policy. |
| [Security](../../SECURITY.md) | Private reporting, credential handling, signing boundaries and outstanding vendor runtime updates. |
| [ffmpeg guide](../../apps/macos/Vendor/ffmpeg/README.md) | Build/linkage details, pinned verification, optional behavior and redistribution guidance. |
| [yt-dlp guide](../../apps/macos/Vendor/yt-dlp/README.md) | New guide for setup, onedir runtime, isolation, provenance and the pending security patch gap. |
| [DMG guide](../../apps/macos/scripts/dmg/ReadMe.txt) | Installation aligned with README/site; removed the unqualified Share Extension handoff promise from the locally signed beta guide. |
| [Site guide](../../apps/site/README.md) | Node/lockfile workflow, preview cleanup, visual checks and deployment settings; root privacy policy included in recommended build watch paths. |
| [Asset guide](../../assets/README.md) | Correct command roots, fixture/dark capture guidance and separation of audit screenshots from canonical artwork. |
| [Codex guidance](../../AGENTS.md) / [Claude guidance](../../CLAUDE.md) | Matching commands, documentation references, verification boundaries and privacy build dependency; architectural and privacy constraints retained. |
| [Codex verification skill](../../.agents/skills/verify/SKILL.md) / [Claude verification skill](../../.claude/skills/verify/SKILL.md) | Identical fresh-build, native UI, media/transfer fixture, cleanup and evidence workflows. |
| [Code of Conduct](../../CODE_OF_CONDUCT.md), [LICENSE](../../LICENSE), [robots.txt](../../apps/site/public/robots.txt) | Reviewed; no implementation-dependent correction needed. |
| [Documentation index](../README.md) and [audit overview](2026-09-06-overview.md) | Linked the complete set of living guides, audit evidence and remaining limits. |

## Consistency decisions

- Source capabilities can be ahead of the published beta; release notes remain authoritative for
  shipped installers.
- A locally valid code signature does not imply Developer ID identity or Apple notarization.
  The paid membership/demand note remains brief in product and installation material.
- Required audio that cannot be resolved fails preparation. A later failure of every mux backend
  can still produce a video-only result; the docs do not conflate these behaviors.
- Manager/app relaunch evidence does not establish physical power-loss durability.
- The latest audited yt-dlp release still has frozen runtime updates outstanding, including a
  newer OpenSSL security patch. TypeScript remains on the newest compatible major for Astro Check.
- Cloudflare watch paths and preview settings are configuration guidance. Local validation does
  not confirm a production deployment or change the dashboard.

## Verification

- All 24 Markdown/text documentation files were checked for local links and balanced code fences:
  local references, Markdown anchors and code fences resolved. The final pass also included the
  added native-policy and screenshot links.
- Source review confirmed README feature boundaries and app/helper/DMG/live-test command paths.
- Astro check passed for 20 files with zero errors, warnings or hints; the production build
  generated home, privacy and 404 successfully. Logs are session-local at
  `/tmp/cloakdrop-docs-site-check.log` and `/tmp/cloakdrop-docs-site-build.log`.
- The rendered policy displays September 6, 2026 and all nine policy sections. Inspected a
  1280 × 900 light desktop view and 390 × 844 dark mobile view, including body/list wrapping.
  No horizontal page overflow or browser warning/error was observed. Temporary appearance and
  viewport overrides were restored, the preview tab closed and the preview server stopped.
- [Mobile policy screenshot](images/2026-09-06-site-privacy-mobile.png).

- The native policy replaced nine localized strings with all 90 translations. The catalog remains
  494 strings across ten translated locales; translation and placeholder validation passed.
- Strict SwiftLint passed across the app/core source. A fresh arm64 Debug app build passed with
  no warning/error in its log (`/tmp/cloakdrop-docs-app-build.log`).
- In the rebuilt app, Privacy settings showed the new date and wording. Inspected the header,
  longer browser/helper paragraphs, licensing section and all three footer links in the native
  dark window. Text wrapped without clipping, the page scrolled to its footer, and the policy
  link's accessibility destination matched the source document. No app preference was changed.
  Settings was closed after verification.
- Native screenshots: [policy header](images/2026-09-06-app-privacy-header.png) and
  [policy body/footer](images/2026-09-06-app-privacy-body.png).

The original engine test/build evidence remains in the
[implementation audit](2026-09-06-overview.md). Core tests were not repeated for the documentation
and localized-policy-only follow-up. No release or website was published during documentation
verification; subsequent source promotion is handled separately by pull request.
