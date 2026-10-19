# Approved hyperlink treatment — 2026-10-19

The user reconfirmed angled hyperlinks and asked to preserve the approved Air design.
Air 1.0.5 (`94c5e537752f`) supersedes the straight-link rule introduced in 1.0.4.
Hyperlinks with a cue use ArrowUpRight; forward app actions and same-page jumps
retain ArrowRight. Header/footer navigation and credits keep neutral ink, while
meaningful body links, focus and active indicators retain the existing blue.
Destinations, new-tab behavior and product features are preserved.

Corrects header, source/reading and family hyperlinks to the Lucide angled shape. The generic text-link rule had overridden desktop Source with blue; moving it before header styling preserves the existing compact breakpoint. Footer credits now inherit neutral ink. Body/prose links retain the approved blue. The existing browser suite now detects navigation colour drift, duplicate Source in compact menus and footer credit colour drift. Asset sync, Astro check/build, 20-surface integrity and 18 portability checks pass. All 432 website layouts and 34 journeys pass, including native compact menus, keyboard, reduced motion, forced colours, long content and no-JS recovery. Native app, installer, RC tag and published artifacts are unchanged.

The family link review covers 22 required viewport/theme cases per app plus two
320px/200% text cases (120 total), compact-menu opening/Escape/focus restoration,
neutral Source colour and decorative icon hiding. Desktop/laptop/phone light/dark
navigation captures were visually inspected. This bounded correction does not
complete the unfinished Resume/IMG migrations or physical/assistive acceptance.

Evidence: `evidence/hyperlinks-2026-10-19/`; full captures and command logs remain
in `/tmp/air-hyperlinks-2026-10-19/`. Root/PDF/Drop are deployed and production-verified;
Resume/IMG remain local.

## Production verification

[PR #41](https://github.com/cloakyard/cloakdrop/pull/41) merged candidate `78cd914`
to main `e3edf4e`. Cloudflare build `5c203b9f-e464-4e13-89bd-c7e13056a2a0`
deployed version `f55dfdb2` at 100% traffic. All remote checks pass.
All 17 production files match the tested SHA-256 bytes; no-transform and
missing-route behavior pass. All 24 live viewport/theme/text cases pass, including
angled hyperlinks, neutral Source/credits and compact menus. Live desktop/laptop/
phone light/dark captures were inspected. Evidence is in
`evidence/hyperlinks-2026-10-19/production/`. Release tags, native apps and published
installer assets are unchanged.
