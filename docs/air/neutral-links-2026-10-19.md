# Neutral hyperlinks — 2026-10-19

The user identified blue content links after the earlier navigation-only fix,
explicitly included Cloakyard, required a design-system rule, and confirmed that
hover must not turn text blue. Air **1.0.6** (`e7c8a4bcfbc5`) supersedes the blue
body-link permission in 1.0.5. The canonical contract's “Landing navigation and
text resilience” section owns the rule; generated DESIGN.md and local bundles
carry it without requiring a sibling checkout.

- Public-page hyperlink text is neutral in default, visited, hover, focus and
  active states. Standalone links use ink; supporting navigation uses secondary
  ink; inline links inherit prose, with a 1px underline and 3px offset.
- Preserve angled ↗ destination cues, original destinations and button hierarchy.
  Same-page/forward actions retain their meaningful arrow. Hover may underline or
  strengthen neutral ink. Keyboard focus keeps its 2px blue outline; active
  indicators and system forced colours remain accessible. Author output is unchanged.
- The shared `test:air-links` browser command examines all visible anchors and
  nested text at required viewports, compact menus, 200% text, hover and keyboard
  focus. It ships in each repo. Supply SITE_URL, AIR_ROUTES, AIR_EVIDENCE_DIR and
  an external PUPPETEER_MODULE. For state-routed privacy pages, set AIR_OPEN_LABEL
  and AIR_OPEN_TARGET so the checker verifies the actual opened surface.

Drop's source/privacy invitations, three installation links and four policy
links now use neutral ink. Inline underlines remain, and standalone hover gains
an underline. Asset sync, Astro check/build, 20-surface integrity, 18 portability,
432 layouts and 34 journeys pass, with no script errors or foreign requests.
The full website suite now rejects non-neutral content links as well as navigation.

Evidence: `evidence/neutral-links-2026-10-19/`; full captures, raw browser results
and command logs are in `/tmp/air-neutral-links-2026-10-19/`. Final local and production visual reviews are complete. No native code, release
tags, installer assets, document/image output or link destinations changed.

Local all-link checks pass: 328 layout/state cases and 116 keyboard focus checks. Desktop/laptop/phone light/dark captures were visually inspected, including page content and policy text.

Checker hardening: use an OS-created unique temporary directory when no evidence directory is supplied. The default-directory browser run passes 60 layout/state and 18 keyboard checks; canonical formatting/lint and portable synchronization pass. This resolves the CodeQL temporary-file finding without changing shipped website assets.

## Production verification

Merged through dev → main in PRs #42 and #43; deployed main `51f178d`. Cloudflare version `467ce2a7` serves 100% of traffic. All release checks now report success, including the corrected shared checker’s CodeQL analysis in PDF. Completed job logs corroborated the temporarily delayed GitHub badges.

All 17 deployed files match the local SHA-256 values; no-transform and missing-route behavior pass. The live browser check passes 328 layout/state cases and 116 keyboard checks, with no non-neutral link text or browser errors. Desktop/laptop/phone light/dark captures were visually inspected.

Production evidence is in `evidence/neutral-links-2026-10-19/production/`. Release tags and native/installer assets are unchanged.
