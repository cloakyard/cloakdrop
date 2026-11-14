# cloakdrop web dependency and Air audit — 2026-11-09

The website now carries Air 1.7.0 and current compatible web dependencies:
Astro 7.4.7, Wrangler 4.158.0 and npm 12.2.2. Native app code, packaged runtimes,
release assets and unpublished native history are unchanged.

The family audit covers this site's home, privacy, recovery, mobile menu, footer,
link states and finite artwork at phone, tablet, laptop and desktop sizes in both
themes. The family run passed 648 public, 288 secondary and 408 privacy cases,
with 22 privacy journeys. Chromium and WebKit each passed 132 moving artwork
layouts, 24 fallback states and six lifecycle journeys across the six sites.
This static website has no fabricated PWA notice or browser editor.

Astro check, production build, asset/provenance checks and the worker dry run pass.
The current security audit reports zero known vulnerabilities. TypeScript remains
on 6.0.3: an isolated invocation of this Astro checker rejects stable 7.0.2.
This preserves a working required typecheck; it is a documented compatibility
exception, not an omitted upgrade.

Shared contract, reference controls and motion notes are synchronized. Obsolete
Expand-controls behavior is removed from the portable interactive reference.
The current family evidence is in the Cloakyard repository at
`docs/air/evidence/mobile-simplicity-2026-11-09`; this standalone bundle still
contains its full design contract and does not require a sibling at runtime.

Visual captures are browser evidence. Physical iPhone/Windows, OS keyboards/IME,
actual browser zoom, spoken assistive review and device battery/frame pacing
remain separate acceptance work. The preceding dependency release is deployed through #59; its exact-main checks and production verification are recorded in that PR.
