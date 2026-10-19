# October 19, 2026 — dependencies for 1.0.0-rc.1

The website now uses the latest compatible direct releases checked against npm
and upstream release metadata today. Native dependencies are already at the
current stable versions. The official yt-dlp runtime exception was explicitly
reconfirmed by the maintainer; no custom Python build pipeline was added.

| Component | Resolved version | Decision |
| --- | --- | --- |
| Astro | 7.4.0 | Updated from lockfile 7.3.6; Node minimum 22.22.0 |
| Wrangler | 4.151.2 | Updated from 4.148.0 |
| Astro Check / Sitemap | 0.9.10 / 3.7.4 | Current |
| TypeScript | 6.0.3 | Latest supported; Check's peer range excludes 7.0.2 |
| GRDB | 7.11.1 | Current stable, unchanged |
| FFmpeg | 9.0.2 | Current stable; already pinned in source |
| yt-dlp | 2026.08.19 | Current official stable bundle; runtime exception below |
| Air Shaders | 4.0.4 | Current pinned local runtime, unchanged |
| checkout / setup-node actions | 7.0.1 / 7.1.0 | Updated and pinned to release commit SHAs |

Primary sources: [Astro](https://github.com/withastro/astro/releases),
[Wrangler](https://github.com/cloudflare/workers-sdk/releases),
[Astro Check](https://www.npmjs.com/package/@astrojs/check),
[GRDB](https://github.com/groue/GRDB.swift/releases),
[FFmpeg](https://ffmpeg.org/download.html),
[yt-dlp](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19),
[checkout](https://github.com/actions/checkout/releases), and
[setup-node](https://github.com/actions/setup-node/releases).

The regenerated npm lock removes obsolete fast-uri and Miniflare/sharp overrides.
Their normal dependency ranges now resolve the patched versions (fast-uri 3.1.8,
sharp 0.35.5). Current Wrangler pins Miniflare 5.20261019.0-beta and workerd
1.20261019.1. No forced incompatible transitive majors were introduced. A fresh
`npm ci` replaces the previously mixed npm/pnpm local install. `npm ls --all`
reports a valid tree and `npm audit` reports zero vulnerabilities.

## Accepted official-bundle exception

The official yt-dlp archive still freezes older Python, OpenSSL, SQLite and Python
packages, including Python 3.14.6 and OpenSSL 3.5.7. Retaining the current extractor
does not update those components. The maintainer chose **keep the official bundle
and document the exception** for this RC, continuing the October 7 decision.
Do not replace individual frozen modules or claim that every bundled library is
latest. Revisit when an upstream complete bundle updates the runtime, or when a
custom build is separately authorized and validated. Full inventory and security
context: [September audit](2026-09-06-dependencies.md) and
[vendor guide](../../apps/macos/Vendor/yt-dlp/README.md).

Pinned source SHA-256 values:

- FFmpeg 9.0.2: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`.
- Official yt-dlp macOS archive: `07e54b0865303c864006925913bce2604f8ee8cc6f18699bac9c309f9328a6d8`.

## Verification

- Node 24.22.0 / npm 11.19.1: clean install, dependency tree and audit pass.
- Asset sync, Astro check (zero diagnostics), three-route build and Wrangler dry
  run pass. Local Wrangler serves `no-transform` on home, privacy and true 404.
- 432 layout cases, 34 journeys, zero script errors or foreign runtime requests;
  real GPU horizon lifecycle and six static fallback profiles pass. Desktop,
  laptop and phone light/dark renders were visually inspected.
- Air integrity: 19 inventory records and 18 isolated portability assertions pass.
- Native arm64 Debug and optimized Release build 20261019 pass with no compiler
  warnings/errors. SwiftLint: zero violations in 174 files. Localization: 494
  source strings across ten translations pass.
- Full optimized core suite: **626 tests in 87 suites**, comprising 14 persistence,
  341 model and 271 engine tests; all pass without feature skips. This includes
  loopback transport, persistence/resume and actual available FFmpeg mux checks.

Website proof and six reviewed PNGs are in
[`docs/air/evidence/dependencies-2026-10-19`](../air/evidence/dependencies-2026-10-19/).
Local detailed logs: `/tmp/cloakdrop-1.0-2026-10-19/`. No native UI or behavior was
changed in this dependency piece. Physical devices, assistive technology, provider
coverage and production deployment remain separate gates. The RC packaging audit
records the final artifact and signing limitations separately.
