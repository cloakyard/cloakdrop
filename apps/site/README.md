# CloakDrop website

**The Air website for CloakDrop.**

[Website](https://drop.cloakyard.com/) · [Product README](../../README.md) · [Support](https://ko-fi.com/sumitsahoo21)

## Overview

The static Astro website for [CloakDrop](https://drop.cloakyard.com/), hosted as a Cloudflare Worker. The native macOS app lives separately in [`../macos`](../macos); this directory owns the landing, privacy and recovery pages.

## Features

A finite product illustration, clear download/installation guidance, real native-app screenshots and the shared Air header/footer. Navigation and policy reading remain useful without JavaScript. The small local script adds Escape, anchor focus and active-section behavior.

Teal square pixels form FILE, PKG, ISO and ZIP once, then rest. The shared lifecycle pauses offscreen/hidden and respects reduced motion, forced colours, Save-Data and constrained devices. After completion, the artwork itself accepts a deliberate replay; there are no separate playback controls.

## Privacy

The site serves static assets without analytics, external fonts, a database or media uploads. Cloudflare handles website requests. Native-app processing and network behavior are described separately in the [root privacy policy](../../PRIVACY.md); the website preserves that policy and its genuine revision date. Keep policy sources and displayed copy aligned.

## Getting started

Visit [drop.cloakyard.com](https://drop.cloakyard.com/) for the product and published downloads. The website links to the [GitHub Releases index](https://github.com/cloakyard/cloakdrop/releases) so prereleases remain visible. Source versions, available releases and signing status are distinct; preserve the current [root installation guidance](../../README.md#getting-started).

## Development

Use the Node range in `package.json` (`^22.23.4 || ^24.15.0 || >=26.0.0`) and the pinned npm 12.2.2. From a full repository checkout:

```sh
cd apps/site
npx --yes npm@12.2.2 ci
npm run dev
```

| Command | Purpose |
| --- | --- |
| `npm run check` | Astro type checking |
| `npm run build` | Sync source assets and build static `dist/` |
| `npm run preview` | Serve the production build |
| `npm audit` | Check the dependency graph |
| `npx --yes knip@6.44.2` | Audit the web module/dependency graph |

TypeScript 6 is retained for the supported Astro checker. Astro 7 may leave a server running after the command returns; stop owned servers with `npx astro dev stop` or `npx astro preview stop`.

### Browser verification

After a production build, run preview on a fresh local port (8824 for this review),
then run from the repository root:

```bash
SITE_URL=http://127.0.0.1:8824 node scripts/test-air-site.mjs
SITE_URL=http://127.0.0.1:8824 node scripts/test-air-artwork.mjs
```

This test requires Chrome and an available `puppeteer-core` installation. Set
`CHROME_PATH` and `PUPPETEER_MODULE` (absolute module path or file URL) when those
are not locally resolvable. It adds no production dependency. `AIR_EVIDENCE_DIR`
selects the parent for a private temporary evidence directory; the printed path includes the full size/theme/root-font
matrix, open/closed menus, contrast, anchors, policy, 404, no-JS and metadata checks.
The artwork suite checks all four silhouettes, fixed download actions, finite completion,
offscreen/Back restoration, live reduced-motion changes and static fallbacks. It
also validates desktop/laptop/mobile, both themes and enlarged text. The pixel
script is absent from privacy/404 routes; its source attribution ships at
`/pixel-art.LICENSE.txt`.
Actual Firefox/Safari review and physical/assistive limits are recorded separately
in [the Air validation record](../../docs/air/validation.md). Use a fresh port if an
older app's service worker controls a reused local origin; do not clear user data.

## Design and assets

Read the complete portable [DESIGN.md](DESIGN.md) before visible changes. The pinned `src/styles/air.css` owns shared tokens, controls and page geometry; `src/styles/global.css` owns product composition. Product colours stay in artwork.

The root `scripts/sync-assets.mjs` copies marks, icons, native screenshots and the OG card from [`../../assets`](../../assets). Edit those sources, then run `npm run sync:assets` or rebuild. Generated public copies are not the source of truth. Screenshot content is illustrative; it contains no personal media.

The [surface inventory](../../docs/air/surfaces.json) and dated audits record actual verification separately from the design reference.

## Project structure

```
apps/site/
├── astro.config.mjs        # static config + sitemap; site = drop.cloakyard.com
├── wrangler.jsonc          # Cloudflare Workers static-assets (serves ./dist)
├── public/
│   ├── robots.txt          # tracked
│   └── cloakdrop-mark.svg, icons/favicon.svg, *.png …
│                           # brand assets — GENERATED from /assets by sync-assets (git-ignored)
└── src/
    ├── data/site.ts        # shared product copy, links, and structured section content
    ├── layouts/BaseLayout  # <head>, SEO/OG, JSON-LD, Air theme colours
    ├── components/         # Landing sections plus shared Brand · Icon components
    ├── pages/index.astro   # landing page — composes the sections in order
    ├── pages/privacy.astro # renders the repo-root privacy policy for the web
    ├── pages/404.astro     # static not-found page used by Cloudflare
    ├── scripts/navigation.ts # native disclosure/anchor focus and active navigation
    └── styles/global.css   # site composition; imports the pinned air.css bundle
```

Product copy and links live in [`src/data/site.ts`](src/data/site.ts). The [root documentation](../../docs/README.md) links release and verification records.

## Deployment and releases

Promote verified changes through a `dev` → `main` PR and keep `dev` updated. When dev also contains unrelated native work, follow the maintainer's reviewed website-only exception instead of publishing that work. The production Worker is `cloakdrop`; the repository is `cloakyard/cloakdrop` and the build root is `apps/site`.

| Setting | Value |
| --- | --- |
| Production branch | `main` |
| Build command | `npm run build` |
| Deploy command | `npx wrangler deploy` |
| Custom domain | `drop.cloakyard.com` |

Workers Builds uses dashboard-managed Git settings. Production deployment belongs to main; branch/PR builds must use preview versions. Never point a non-production branch at the production deploy command. Check the actual dashboard configuration and exact commit receipt rather than inferring deployment from `wrangler.jsonc`.

Keep watch paths aligned with `apps/site/**`, asset-sync sources, the root policy and imported `docs/air/**` assets. The full checkout is required. Native-only work must not be released by a website merge. CI validates/builds the website; no Cloudflare credentials belong in the repository.

For an explicitly authorized manual deployment, `npm run deploy` checks/builds as configured and publishes. For a local validation only, build first and run `npx wrangler deploy --dry-run`. After publication, verify the exact main build, public headers, routes and asset hashes. Native app releases and notarization are separate; the published [release notes](https://github.com/cloakyard/cloakdrop/releases) own artifact and signing facts.

## Contributing

Read [AGENTS.md](../../AGENTS.md), [CLAUDE.md](../../CLAUDE.md) and [CONTRIBUTING.md](../../CONTRIBUTING.md). Follow the [family README standard](https://github.com/cloakyard/cloakyard/blob/main/docs/README_STANDARD.md), keep shared Air patterns portable, and record browser coverage without claiming unperformed hardware tests.

[Buy me a coffee](https://ko-fi.com/sumitsahoo21) supports the project.

## License

Released under the [MIT License](../../LICENSE). Third-party components retain their own notices.

Built by [Sumit Sahoo](https://github.com/sumitsahoo), part of [Cloakyard](https://cloakyard.com/).
