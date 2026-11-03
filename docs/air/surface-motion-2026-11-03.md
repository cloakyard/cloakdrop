# Air 1.5.0 — surface motion, 2026-11-03

Website-only Air 1.5.0: native navigation and reading disclosures fade consistently and retain immediate opening focus. Native code and the eight local unpublished native/release commits are excluded from rollout.

Dialogs use 240ms entry/160ms exit; small surfaces use 180ms/160ms. Reduced motion is immediate. No animation dependency was added. Typing and selection remain immediate.

## Verification

- Asset synchronization, Astro check and production build passed.
- Portable design/provenance and standalone checks passed.

The six-site comparison passes 648 home/288 secondary layouts, 408 privacy layouts and 22 navigation journeys. The three PWAs match in 396 real-worker notice layouts. Shared presence passed 170 Chrome/WebKit observations plus the focused final regression pass.

See [the family audit](https://github.com/cloakyard/cloakyard/blob/main/docs/air/family-motion-2026-11-03.md) and local evidence. Physical iPhone/software-keyboard, OS IME and spoken assistive acceptance remain open; automated WebKit does not close them. The recorded product backlog is unchanged.

## Rollout

Passing local piece prepared for an individual dev → main PR; production verification is recorded in the central handoff after merge.
