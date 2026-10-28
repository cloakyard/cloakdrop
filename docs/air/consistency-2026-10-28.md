# Air consistency audit — 2026-10-28

Air 1.2.4 pins the same public compact navigation and correct CSS time conversion
for both seconds and milliseconds. The production light arrival stays 900ms.

Removed duplicate compact-menu row styles; the canonical shell supplies the same spacing and correct open-chevron state as the family. Website checks cover 432 layouts, 34 journeys and the finite pixel artwork. Build/check/dead-code/design/portability pass. Native code, installer and release assets are unchanged.

The four refreshed websites pass 1,152 Chrome/Firefox shell layouts with zero
deviations/errors. PDF/Resume share 264 PWA layouts and 54 exact visual pairs.
The common notices preserve each app's update/work-safety lifecycle. Yard and
Drop's website have no PWA worker. Link states remain neutral, including hover.

[Local evidence](evidence/consistency-2026-10-28/) preserves this candidate's verification.
[The family audit](https://github.com/cloakyard/cloakyard/blob/main/docs/air/consistency-2026-10-28.md)
contains the before/after review, full test ledger and production release tracking.
Deployment is tracked separately from these pre-merge acceptance results.

Full product, physical/assistive/hardware and existing output/security acceptance
items remain open. This audit does not mark those surfaces fully validated.
