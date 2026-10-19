# CloakDrop brand-coloured Air deployment — 2026-10-19

The user explicitly authorized deployment. The validated candidate `a28264f`
was fast-forwarded into dev, then merged through [PR #40](https://github.com/cloakyard/cloakdrop/pull/40)
to main `5ee9a01`. The production tree matches the validated candidate.
Cloudflare build `c42dcc9b-464a-4887-bf8f-872fcb65ad67` succeeded; active version
`38ca8179` serves 100% traffic at [CloakDrop](https://drop.cloakyard.com).

Fresh local checks and production builds pass. All PR and main CI checks pass.
Every deployed build file matches local SHA-256, with no-transform headers:
17 files plus the expected missing-route response (true 404). This includes the
OG artwork and lazy shader. Twelve production viewport/theme cases cover desktop,
laptop, tablet, narrow phones and landscape; both real GPU themes render and
stop at rest. Desktop/laptop/phone light/dark captures were visually inspected.
No browser script errors were observed.

This also completes the main/dev integration of the already deployed Air website
and published RC preparation. RC1 remains the same tag and exact DMG checksum;
no native build or release artifact was replaced.

Evidence: [deployment record](evidence/brand-deployment-2026-10-19/deployment.json),
[asset hashes](evidence/brand-deployment-2026-10-19/live-assets.json),
[responsive/GPU checks](evidence/brand-deployment-2026-10-19/brand-horizons.json)
and adjacent review/deployment images. Full captures/logs remain at
`/tmp/air-brand-deploy-2026-10-19/cloakdrop/`.

Resume and IMG remain local; full-family migration and physical GPU/battery/thermal
and assistive-device acceptance remain open. No credentials or deployment settings
were changed.
