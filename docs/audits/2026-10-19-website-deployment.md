# Air website production deployment — October 19, 2026

The user explicitly requested deployment after publishing RC1. The complete Air
website is live at [drop.cloakyard.com](https://drop.cloakyard.com/), including the
finite horizon animation, 1200×630 OG card, privacy page and true 404 recovery.

## Deployment identity

- Source: `6ac533ffc8dc2a7a5094223dd6d180300ab16ed7`, `codex/air-refresh`.
- Cloudflare Worker: `cloakdrop`; version `f99e2602-7fef-4351-8d53-d51b90c0a455`.
- Build: `3edba187-3214-4435-9980-4b63375f7fb7`, successful in 28 seconds.
- The existing Workers Builds connection built the pushed branch with Node24.21.0,
  npm10.9.2, `apps/site`, `npm run build` and `npx wrangler versions upload`.
  After checking preview asset hashes, this version was promoted to **100% traffic**.
- Production branch remains `main`; non-production builds are enabled, watch include
  is `*`, and production deploy command is `npx wrangler deploy`. Settings were
  inspected, not changed. No new credentials or extension permissions were granted.

## Verification

- Fresh local asset sync, Astro check (18 files, zero diagnostics), production build
  (three routes) and Wrangler dry run pass. Twenty inventory records, 18 portability
  assertions and exact family bundle synchronization pass.
- GitHub [website and contract checks](https://github.com/cloakyard/cloakdrop/actions/runs/39255213152)
  and the Cloudflare build succeed for this exact source.
- **18 live responses** match local bytes by SHA-256, including all public built
  files, the OG image and the missing-route response. Home/privacy return200 and
  the unknown route returns404. Every checked response serves `no-transform`.
- Against the production domain: **432 layouts, 34 journeys, 35 captures**, zero
  script errors or foreign runtime requests. Includes theme/viewport/text matrices,
  menus, focus, anchors/history, policy contents, download destination, metadata,
  no-JS, reduced motion, forced colours and 404 recovery.
- Real GPU arrival/pointer/idle/theme/offscreen/Back restoration/reduced lifecycle
  and **six static fallback profiles** pass; privacy loads no artwork renderer.
- Visually inspected live desktop1440, laptop1280 and phone390 in both themes,
  plus phone privacy dark and 404 light. Layout, content and controls remain intact.

The lazy shader produces the already documented >500kB uncompressed chunk advisory;
the build enforces its separate 350kB gzip budget and the lifecycle checks pass.
This deployment changes no native application or published RC artifact.
Physical touch, spoken assistive and GPU/battery/thermal acceptance remain separate.

## Evidence and continuation

[Deployment identity and checks](../air/evidence/deployment-2026-10-19/deployment.json),
[live response hashes](../air/evidence/deployment-2026-10-19/live-assets.json),
[browser results](../air/evidence/deployment-2026-10-19/website.json) and
[horizon results](../air/evidence/deployment-2026-10-19/horizon.json) are committed
with representative screenshots. Full captures/logs are at
`/tmp/cloakdrop-deploy-2026-10-19/`.

Main/dev were not merged; integrate the Air source before another main-triggered
website deployment so the older branch cannot replace this version. The production
promotion is complete and independent of that remaining repository integration.
Resume's colour wheel remains the next family UI piece; IMG stays last.
