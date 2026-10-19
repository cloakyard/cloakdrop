# Air validation record

## 2026-10-11 — portable contract and inventory

Website Astro check: 19 files, zero errors/warnings/hints. Asset sync and production build pass (home, privacy, 404). No native source changed.

`node scripts/check-air-design.mjs` passes both in this repository and in a
separate temporary directory with only DESIGN.md, the checker and inventory.
Regenerating the inventory preserves its contents. The contract is copied in full;
there is no sibling-checkout or runtime service dependency. CI checks document
integrity and inventory drift; source files default to pending until reviewed.

This commit establishes governance only. Runtime Air styles, component/state audits,
responsive screenshots and feature sweeps are still pending. The full phased plan
is maintained in Cloakyard's `UX_REFRESH_TODO.md`; this repository's surface record
tracks local evidence so it remains usable independently.

## 2026-10-11 — shared component bundle

The pinned local CSS and working `docs/air/components.html` reference are identical
across the family. They are not yet imported into product screens. Contract/bundle
hashes, palette equality and standalone-copy validation pass. All 15 required and
breakpoint-neighbour viewport sizes have no document overflow in light and dark.
The reference was visually inspected on desktop, laptop and phone, including the
390px dark sheet and 320px light controls. Evidence images are recorded in the
family repository's `docs/air/evidence/reference-*.jpg`.

Verified: field/select editing; checkbox and segment selection; slider keyboard
increment; dialog initial focus, forward/reverse focus wrap, Escape, Done and focus
return; 44px coarse-pointer controls; 16px mobile inputs; zero-duration reduced
motion. Fixed the native dialog's default max-width narrowing the phone sheet.
Contrast calculations: all tested normal text/semantic pairs >=4.5:1; required
field boundaries >=3:1 (light 3.31:1, dark 4.39:1). Source review covers disabled,
busy, hover/press and status variants. Product-specific controls, real app state
sweeps, 200% browser zoom and software-keyboard behaviour remain separate gates.

The CSS is imported only by the standalone HTML reference. The Astro production
site does not import it; production adoption remains a separate reviewed piece.


## 2026-10-12 — complete website baseline audit

[The source-linked audit](website-audit.md) records the current website and its
migration findings. All 18 production source files were reviewed; the inventory
now includes shared content, screenshot geometry and navigation TypeScript.
The nineteenth entry is the opt-in family CSS. Production Air implementation and
validation remain false for every production source.

Evidence: 90 normal-layout cases, 24 header journeys, 40 targeted observations,
370 computed opaque-background text pairs, 12 enlarged-root-font cases and 16
visually inspected captures. The dark skip link fails contrast; narrow home/404
fail enlarged-text reflow. Tablet composition, coarse targets, keyboard motion and
no-JS same-page menu dismissal are migration findings, not silently passing tests.
The functional baseline covers navigation, recovery, download destination and
source-policy rendering. See the audit for the limits of browser emulation and
remaining physical-device, actual zoom and cross-engine coverage.

The copied refinement 03 reference includes the shared motion module and locally
bundled Shaders study. Its earlier family validation is recorded in Cloakyard's
motion/light evidence; local integrity and isolated portability are checked here.
This checkpoint changes documentation, inventory tooling and opt-in design assets
only. It does not restyle the live website or native application. The user's
2026-10-12 decision is to keep refining Air before rollout.

Final gates: asset sync (all seven up to date), Astro check (19 files; zero
diagnostics), three-route production build, portable contract/bundle checker,
five isolated portability assertions, evidence-preserving inventory regeneration
and `git diff --check` pass. No tracked native or production UI files changed.


## 2026-10-12 — refinement 03 reference checkpoint

Saved the canonical Air candidate from Cloakyard checkpoint `340aee8`, contract
`dc6032235f40` (SHA-256 prefix). The standalone bundle includes refined fields,
choices, compound controls, motion, floating menus/popovers/tooltips and safe
rename/remove/restore studies, plus local shader/overlay modules and licenses.
`design:portability` exposes the isolated validation command. Generated vendor
assets are covered by hash verification, not reformatted as app-owned source.

The exact-copy contract checker and all ten isolated portability assertions pass
for this product (13 files, no app dependencies or sibling checkout). Shared
reference visual and interaction evidence is recorded in Cloakyard's
`docs/air/validation.md`, including 224 floating-surface checks and 15 journeys.
This is a documentation/reference checkpoint; the runtime does not import Air CSS
or the study modules, and full product visual/feature migration is still pending.

Website `npm run check` passes for 19 files with no errors, warnings or hints.
`npm run build` passes for home, privacy and 404; its asset-sync hook reports
all seven assets current. No native macOS sources are changed.

Existing product behavior and appearance are unchanged. Runtime editor/AI/export
E2E sweeps are reserved for affected production pieces; this checkpoint does not
claim those have passed. No push or deployment was performed.


## 2026-10-14 — Portable Air 1.0.1

Pinned the complete family contract and reference bundle to Air 1.0.1 (contract
`201f7c381b5f`). Header identity is now consistently 36×36px across landing/editor
and small screens, with at least a 44px interactive target. A shared paper-accent
keeps selection chrome readable on white document paper in both themes. Inventory
version comes from the manifest. The new token does not change this product's
runtime controls; its full application migration remains separately tracked.

Exact design integrity, isolated portability and production checks pass. Shared
visual/interaction evidence is in CloakPDF's canvas checkpoint; it does not claim
this product's editor, physical touch or assistive acceptance is complete.

## 2026-10-15 — Air 1.0.2 colour-wheel contract

Pinned the portable colour-wheel rules, opt-in CSS, shared math/types and working
reference. Product picker runtime adoption remains separate from this bundle sync.
Asset sync, Astro check (19 files, zero diagnostics) and three-route build pass, as do design integrity and all 18 standalone portability assertions.
No product UI source or dependency changed. The family evidence and PDF pilot are
tracked in Cloakyard's UX_REFRESH_TODO.md; physical/assistive acceptance remains open.

## 2026-10-19 — shared disabled icon-button correction

Synchronized the canonical Air CSS and gallery hashes. Guarded `aria-disabled`
icon buttons now use the same disabled appearance as text buttons and cannot
show hover/press motion. No product component or native macOS source changed;
this bundle update is not a completed app migration. Contract stays Air 1.0.2,
`bb90f52e0b0a`; exact assets are pinned in bundle.json. Real behavior/visual evidence
is recorded in CloakPDF's editor-wrappers-2026-10-19 audit and Cloakyard's matching
validation checkpoint. Required site asset sync, Astro check (19 files with zero errors/warnings/hints), three-route production build, design integrity and all 18 portability checks pass.

The final correction keeps the keyboard focus contour at full opacity while muting
only the unavailable icon; the synchronized bundle was rebuilt and rechecked.


## 2026-10-19 — Complete Air website and social preview

Home, navigation, product/craft/privacy, install/download, footer, policy and 404
now use the pinned family CSS directly. The in-flow native menu works without JS;
Escape and link activation preserve focus. Same-page links retain Back/Forward and
sequential keyboard navigation. A native Firefox check caught focus returning to
the top after a policy anchor; explicit history/focus handling fixes it in Firefox
and Safari. Policy contents come from the original Markdown headings; meaning and
the September 6 revision remain unchanged. Unknown routes still return HTTP 404.

The Air OG source imports the pinned CSS and composes the unchanged real Mac app
screenshot at 1200×630. Matching metadata replaces the previous range-map artwork.
Original logos, screenshot renditions, Swift/macOS and policy source have no diff.
No new dependency, font request, runtime service or shader. Deleted the old font
pair (75,332 bytes), redundant stats/Kicker/unused icons, custom palette/skins,
overlay menu, scroll-progress and content-reveal code. Maintained site/asset docs
now describe Air; dated baseline/release audits remain historical.

Production acceptance: **432 layout observations** across 23 sizes, all three
routes, both themes, root-font enlargement and compact menus; **34 journey records**,
**374 passing text-contrast pairs**, 18 policy active-destination checks, 35 primary
captures plus targeted viewport/native views. Checks include actual text bounds,
44px coarse targets, skip/Enter/Space/Tab/Escape, all 24 cross-route header journeys,
contents, history, repeat anchors, no-JS, reduced motion, forced colours, long labels,
404/home, nine built assets and metadata. No script errors or foreign runtime requests.
Two early UI findings (menu alignment and short Craft hit target) were fixed before
the complete passing rerun. Harness failures/repairs and the old local PDF service
worker on reused port 8134 are recorded; Drop review moved to fresh port 8144 without
clearing user storage. Safari light/home/policy/recovery and Firefox actual 200%
zoom/download/policy/keyboard/recovery pass; tabs closed and Firefox zoom restored.

Asset sync, Astro check (17 files, zero errors/warnings/hints), all three built
routes, design integrity and 18 portability assertions pass. Exact family sync
passes. CSS is 44,786 bytes / 8,882 gzip including shared Air controls; inline
navigation is 1,628 / 783 gzip. External Puppeteer is test tooling only. Official
[release index](https://github.com/cloakyard/cloakdrop/releases) still exposes the
beta and the preserved platform/signing/install guidance; no installer was run.

Evidence: `evidence/website-air-2026-10-19.json`, checks log and four PNGs. Full
captures and preserved failed attempts: `/tmp/cloakdrop-air/`. Physical touch and
spoken assistive checks remain open; software keyboard/IME are inapplicable to
this static site. Native install/signing, transfers and deployed edge behavior are
outside this change. Local commits only; no push or deployment. Resume is next,
then the parked IMG draft and full migration last, per the user's corrected order.

## 2026-10-19 — finite landing horizon

The static Astro home mounts the pinned family light runtime below the hero copy
and above the native screenshot. Arrival/pointer motion stops at rest and releases
the device offscreen. Policy/404 routes do not load the renderer. No new dependency
or native-app/image/OG change; 350 kB gzip lazy-shader budget and shipped license.

432 layouts, 34 journeys, 35 captures, real GPU lifecycle and six fallback profiles
pass. The first Back assertion incorrectly expected visible motion after restoring
the footer scroll; corrected to assert offscreen release, then scroll/reactivation.
No runtime workaround or reduced assertions. Asset sync, Astro check/build,
19-source inventory, 18 portability and exact family sync pass. Desktop/laptop/
phone light/dark captures and native Safari rendered horizon/anchor focus inspected.
Evidence: `evidence/landing-horizon-2026-10-19/`; full 35 captures in the website
JSON's temporary evidence directory. Physical touch, spoken assistive and physical
GPU/battery/thermal acceptance remain open. Local commit only; no deployment.

## 2026-10-19 — RC dependency and static delivery recheck

Updated Astro 7.4.0, Wrangler 4.151.2 and compatible transitive packages. Removed
the now-redundant fast-uri/sharp overrides and old install-script allowances.
Node minimum now matches Astro (22.22.0); TypeScript remains supported 6.0.3.
CI pins current actions and checks the website install, types, build and audit.
Cloudflare watch documentation includes the imported Air runtime. Static responses
request `no-transform`; local Wrangler returns that header on home, policy and 404.

Clean npm install, valid full tree, zero audit findings, Astro check, three-route
build, Wrangler dry run, 19-source design check and 18 portability checks pass.
The final build passes 432 layouts, 34 journeys and the real-GPU horizon lifecycle
with six fallback profiles; no script errors or foreign runtime requests. Desktop,
laptop and phone light/dark screenshots were inspected. The Air OG and native UI
remain unchanged. Evidence: `evidence/dependencies-2026-10-19/`; details in
[the dependency audit](../audits/2026-10-19-dependencies.md). Physical/assistive gates
and actual Cloudflare deployment verification remain separate. Local commits only.

## 2026-10-19 — Air installer artwork

The user explicitly extended the refresh to the installer background. Replaced
the old technical card/grid/mono labels with the canonical light palette, regular
system display type, open spacing, a quiet two-plane horizon and one drag arrow.
Actual app/Applications icons and the guide remain at their verified coordinates.
No native application control or transfer behavior changed. The Swift renderer
shrinks from 285 to 142 lines; its 2× PNG shrinks from 872 KB to 112 KB.

Finder's single bitmap is intentionally fixed light artwork, independent of the
app's light/dark UI. The final 760×570-point installer was opened through Finder,
with real icons/labels and no clipping; the background is 1520×1140 at 144 dpi.
Source/render, mounted-DMG review, code signatures, 20-source design integrity,
18 portability checks and exact family specification sync pass.
See [installer evidence](../audits/2026-10-19-installer.md).


## 2026-10-19 — production Air website deployment

After explicit deployment authorization, Cloudflare built source `6ac533f` and
version `f99e2602-7fef-4351-8d53-d51b90c0a455` was promoted to 100% production traffic.
Eighteen live response hashes match the local build; `no-transform` is present on
all checked responses. Home/privacy200 and unknown404 are verified. Live 432 layouts,
34 journeys, 35 captures, real GPU lifecycle and six fallback profiles pass without
script errors or foreign runtime requests. Desktop/laptop/phone light/dark and
phone policy/recovery captures were visually inspected. Astro check/build/dry run,
20-source design, 18 portability, exact sync and remote website/contract checks pass.

[Full deployment audit](../audits/2026-10-19-website-deployment.md) records the source,
build, hashes and screenshots. Main/dev remain unchanged and need Air integration
before another main-triggered deployment. Native/RC artifacts are unchanged;
physical/assistive/device gates remain open.

## 2026-10-19 — brand-coloured production deployment

Dev → main PR #40 merged as `5ee9a01`; Cloudflare version
`38ca8179` is active at 100%. Fresh checks/builds and remote CI pass.
Exact live asset hashes, twelve responsive/theme cases, both real GPU themes
and idle checks pass; desktop/laptop/phone light/dark states were inspected.
[Deployment audit](brand-deployment-2026-10-19.md) contains the source/build identity
and evidence. Resume/IMG remain local; physical/assistive acceptance remains open.

## 2026-10-19 — consistent landing arrows

Air 1.0.4 uses straight forward-navigation arrows. See
[scope, validation and evidence](link-arrows-2026-10-19.md). Twenty-two responsive
light/dark cases and two enlarged-text cases pass, including compact-menu
keyboard return; desktop/laptop/phone captures were visually inspected.

## 2026-10-19 — approved angled hyperlinks and neutral navigation

Air 1.0.5 restores the approved angled hyperlink cue and neutral header/footer
treatment. See [scope and evidence](hyperlinks-2026-10-19.md). Twenty-four local
responsive/theme/text cases pass; desktop/laptop/phone captures were inspected.

Production correction: PR #41, main `e3edf4e`, version `f55dfdb2`
at 100%. All 17 asset hashes and 24 live link/layout cases pass.

## Neutral hyperlink follow-up — 2026-10-19

Air 1.0.6 removes blue hyperlink text, including hover, and specifies neutral
inline/directional treatments. See [scope and evidence](neutral-links-2026-10-19.md).
