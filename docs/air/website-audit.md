# CloakDrop website baseline audit

Audited 2026-10-11–12 against the portable Air contract and
[Web Interface Guidelines](https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/main/command.md).
This records the existing production website. No product UI or native SwiftUI code
was changed. On 2026-10-12 the user requested further Air refinement before rollout.

## Findings for the migration

### Shared styles and typography

- `apps/site/src/styles/global.css:331` — dark-mode skip-link text is white on
  `#5eb6c9`, only **2.33:1**. Use the shared primary-action foreground for its
  background and verify focused text in both themes.
- `apps/site/src/styles/global.css:334` — keyboard focus animates the skip link's
  `top` over 200ms. Air focus and keyboard feedback must be immediate.
- `apps/site/src/styles/global.css:290` — generic active translation also applies
  to keyboard activation. Adopt Air's pointer-only press and immediate release.
- `apps/site/src/styles/global.css:28` — unused legacy token candidates include
  `--accent-strong`, `--accent-soft`, `--tint`, `--shadow-window`, `--shadow-card`,
  `--t-h3-lg` and `--t-h2-band`. Searches of site source found declarations without
  consumers. `.rule` and `.btn--sm` also have no source consumers. Recheck dynamic
  use and remove them with the corresponding migration; do not retain a second scale.
- `apps/site/README.md:8` — the implementation description still specifies the
  editorial typography/colour system. Update it when Air lands; keep dated audits historical.

### Header, brand and navigation

- `apps/site/src/components/Brand.astro:27` — measured 40px brand hit area on coarse
  pointers; Air requires 44px. At 320px/200% root font, the wordmark fragments over
  several lines. Define a compact accessible lockup with sufficient hit area.
- `apps/site/src/components/Header.astro:107` and `:152` — desktop navigation and
  Source stay 40px high above the 900px breakpoint, including touch tablets.
  Target sizing must follow input capability independently of layout width.
- `apps/site/src/components/Header.astro:258` — keyboard menu entry runs the same
  220ms animation as pointer entry. Keep keyboard entry immediate and use Air's
  shared timing/origin/interruption rules for pointer entry.
- `apps/site/src/scripts/motion.ts:80` — same-page menu dismissal depends on JS.
  With scripting disabled, the link navigates but the popover remains over the
  destination until explicitly closed. All content and the native close control
  remain available. Consider an in-flow navigation fallback during migration.

### Home, craft and error composition

- `apps/site/src/components/Hero.astro:53` — bottom-aligned split columns leave
  excessive blank space above the title at 768px. At 844×390 the title and primary
  action are below the initial viewport. Use the shared compact landing composition
  when the title, explanation and action cannot form one readable group.
- `apps/site/src/components/Product.astro:26` — the auto-sized header grid exceeds
  a 320px viewport under 200% root-font stress; the section reaches about 383px.
  Permit content shrink/wrap without hiding the overflow.
- `apps/site/src/components/Provenance.astro:43` and `:60` — craft grids exceed
  their narrow content area under the same stress. Content reaches about 355px
  and the chamber clips it. Audit grid minimums, inner padding and icon columns.
- `apps/site/src/components/Provenance.astro:58` — the 4px hover arrow is ungated.
  Adopt Air's 2px fine-pointer arrow with keyboard/reduced-motion protection.
- `apps/site/src/components/Provenance.astro:45` — hardcoded band colours and grid
  artwork compete with Air's surfaces. Replace website chrome with shared tokens;
  retain the real native screenshot as product content.
- `apps/site/src/pages/404.astro:70` — its one-column layout reaches about 367px
  at 320px/200% root font, clipping the title and recovery action. Use shrinkable
  tracks and a compact recovery layout; preserve the working home destination.
- `apps/site/src/scripts/motion.ts:19` — section reveals use 12px over 550ms even
  when a keyboard anchor brings them into view. Replace with the approved Air
  arrival rules; do not animate frequent keyboard navigation.

## Verified baseline behaviour

- Astro check: 19 files, zero errors/warnings/hints. Asset sync and production build pass.
- **90 normal-layout DOM cases**: 15 sizes × both themes × home/privacy/404.
  No measured horizontal overflow in main/footer, broken images or foreign asset
  requests. These measurements are not a claim of visual review at all 90 cases.
- **24 header journeys**: every Product/Craft/Privacy/Download destination from
  home, privacy and 404 at 1280px/light and 390px/dark. Correct hashes, active links,
  targets below the sticky header, and menu dismissal with JavaScript enabled.
- Native menu keyboard/pointer open/close, first Tab, Escape and focus restoration
  work. The landscape menu scrolls and keeps its last destination reachable.
- The skip link moves sequential keyboard navigation to the first main action.
  Reduced motion disables menu animation and smooth scrolling.
- The download CTA reaches the official GitHub releases index. The current listed
  beta has an accessible `.dmg` asset link. No installer was downloaded or run.
- Privacy navigation renders the nine source-policy sections, one visible h1,
  matching 2026-09-06 revision and correct canonical URL. Root `PRIVACY.md` remains
  the source; this is a rendering check, not a legal review.
- An unknown local route returns **HTTP 404**, the custom page and `noindex`.
  Its recovery action returns home. This uses Astro preview, not a deployed edge test.
- **370 computed text pairs** on opaque backgrounds: 367 pass the applicable
  4.5:1/3:1 threshold; the three failures are the shared dark skip link on each
  route. Gradient-decorated ancestors are excluded from this numerical check.
- **12 root-font stress cases**: 1280px/320px × both themes × three routes, with
  `html` temporarily set to 200%. Desktop and narrow privacy fit; narrow home and
  404 overflow in both themes. This is text stress, not actual browser zoom.
- With scripting disabled, content, native menu controls and anchor destinations
  remain available. Same-page dismissal needs the explicit close as noted above.
- No console warnings/errors were observed in the audit log. Native macOS code
  and shared brand/screenshot source assets have no changes from this audit.

## Evidence and limits

`evidence/website-baseline-2026-10-11.json` holds the original 90 measurements.
`evidence/website-interactions-2026-10-12.json` holds 40 targeted observations,
contrast pairs, text-stress results, limits and the 16 named screenshot captures.
Those captures were visually inspected, including desktop/laptop/tablet/phone,
landscape, menu, download, privacy, 404, feature/craft sections and failing reflow.
Browser overrides were restored and the temporary browser tab closed.

Physical touch devices, Safari/Firefox, assistive technology, actual browser/text
zoom and post-migration feature/visual regression remain required. There are no
web forms or editors here, so software-keyboard/editing tests are not applicable
to the current website. Native install/signing/checksum verification is outside
this website refresh. None of the production surfaces is marked Air-implemented
or validated on the strength of this baseline.

## Migration checkpoint — 2026-10-19

The original findings above are historical. The complete static website now uses
Air; its software acceptance is recorded in `evidence/website-air-2026-10-19.json`
and the dated validation record. Physical touch and spoken assistive acceptance
remain open. No native app UI or behavior changed.

## Migration checklist

- [x] Fix the source-linked contrast, reflow, input-target and motion findings.
- [x] Adopt Air for home, navigation, footer, download, privacy and 404 together;
      keep truthful release/install/OS information and the real native screenshot.
- [x] Remove replaced styles, unused tokens/classes, old font assets when unused,
      old artwork and authoritative editorial styling instructions.
- [x] Re-run the full matrix, enlarged-text, keyboard/no-JS/routes and named views;
      native Safari and Firefox actual 200% zoom checked.
- [ ] Physical touch and spoken assistive acceptance remain open.
- [x] Preserve source policy rendering, HTTP 404 and release-index destination.
- [x] Run sync/check/build and design gates, inspect diffs, then commit the piece.
