# App-coloured Air horizon — 2026-10-19

The user requested app colours across all family landing pages. cloakdrop uses its
original logo's teal (#338DAB / #5FCDD6), primary stop for light and highlight for dark.
Air 1.0.3 (`abcaee334ca7`) owns the five artwork-only tokens. The wrapper's computed
`color` feeds the existing shader and SVG `currentColor` fallback. Shared focus,
controls, page planes, motion/lifecycle and actual product output retain their rules.

Astro check/build, 20 inventory records and 18 portability checks pass. Production-preview site acceptance covers 432 layouts and 34 journeys; the horizon gate passes real GPU lifecycle and six static fallback profiles. Native app, dependencies, published RC and installer bytes are unchanged.

Twelve viewport/theme cases cover 1440×900 desktop, 1280×720 laptop, 768×1024
tablet, 390×844 and 320×568 phones, and 844×390 landscape. Both real GPU themes
render and stop at rest. Desktop/laptop/phone light/dark captures were visually
inspected, including the static fallback. Evidence: `evidence/brand-horizons-2026-10-19/`.
The family runner is `cloakyard/scripts/test-air-brand-horizons.mjs`; it accepts
`AIR_APP`, `AIR_URL`, `AIR_EVIDENCE_DIR`, `CHROME_PATH`, and `PUPPETEER_MODULE`.
It reads original logo stops, checks computed colours and static/GPU parity, and
uses disposable browser profiles. Full temporary captures/logs are under
`/tmp/air-brand-horizons-2026-10-19/`.

This is a local checkpoint. These colour changes have not been pushed or deployed.
Physical GPU/battery/thermal and assistive-device gates remain open; emulation
and desktop Chromium do not establish those results.
