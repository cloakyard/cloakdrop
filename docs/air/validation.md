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
