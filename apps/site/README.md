# CloakDrop brand site

The marketing site for **CloakDrop**, hosted at **[drop.cloakyard.com](https://drop.cloakyard.com)**.

- **Stack:** [Astro](https://astro.build) 7 — fully static output, with a small first-party
  script for anchor focus and native navigation disclosures.
- **Host:** Cloudflare **Workers static assets** (`wrangler.jsonc` → serves `dist/` from the edge).
- **Design:** the portable **Air** contract in [DESIGN.md](DESIGN.md). Shared `src/styles/air.css` owns system typography, light/dark tokens and controls; `global.css` only composes the site. No font downloads, analytics or external runtime requests.

Part of the CloakDrop monorepo — the macOS app lives in [`../macos`](../macos). Shared brand
assets (logo, favicons, OG card, hero screenshot) live in the repo-root
[`/assets`](../../assets) folder and are copied into `public/` at build time by the root
`scripts/sync-assets.mjs` script (run automatically by the `prebuild` hook). See
[`/assets/README.md`](../../assets/README.md).

The landing-page copy describes the 1.0.0 source tree and macOS 27 support. Until that release is
published, its download note identifies release preparation and links to the available GitHub
builds. Update that note when uploading 1.0.0; keep the download URL on the releases index so it
also works for prereleases. The install note documents local signing and Apple’s
Privacy & Security → Open Anyway flow; keep it aligned with the DMG install guide.

The landing page uses a real app screenshot, three concise feature summaries, an
open-source/privacy sections, and installation guidance. The header uses an in-flow native
disclosure; every destination, policy section and recovery link works without JavaScript.
The small navigation script enhances Escape, active section markers and anchor focus.
The Air hero assembles teal square pixels into FILE, PKG, ISO and ZIP silhouettes.
It uses native Web Animations with a visible pause/resume control, stops offscreen
or hidden, and keeps a static FILE for no-JS/reduced-motion/constrained visits.
These are decorative Lucide-derived pixel masks, not simulated transfers. No
animation library, shader or client-side framework is shipped.

## Develop

Requires **Node 22.22.2+, 24.15.0+ or 26+** and **npm 12.2.0**, matching
`package.json`. Start from the repository root; the remaining
commands in this guide run inside `apps/site/`.

```bash
cd apps/site
npx --yes npm@12.2.0 ci # reproducible install from package-lock.json
npm run dev          # http://localhost:4321 (hot reload)
```

## Build & check

```bash
npm run check        # astro type-check (0 errors expected)
npm run build        # → dist/ (static)
npm run preview      # serve the built dist/ locally
```

Astro 7 can leave the development/preview server running after the command returns. Stop your
server when finished with `npx astro dev stop` or `npx astro preview stop`.

After visual changes, inspect desktop and narrow mobile widths in light/dark appearance,
keyboard navigation (including the mobile menu), reduced motion, enlarged text and the
no-JavaScript fallback. The app screenshot uses an example library; displayed speeds are
illustrative. See the [documentation index](../../docs/README.md#release-verification) for dated
verification results.

## Structure

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

Edit shared product copy and links in [`src/data/site.ts`](src/data/site.ts). The static feature
section lives in [`src/components/Product.astro`](src/components/Product.astro).
The privacy page imports [`PRIVACY.md`](../../PRIVACY.md), including its section headings for contents navigation; update its displayed date in
`src/pages/privacy.astro` when the source policy changes; sync the native Privacy settings page
and its translations too. Keep installation steps aligned with the
[README](../../README.md#download-and-install) and [DMG guide](../macos/scripts/dmg/ReadMe.txt).
Brand assets
(the `cloakdrop-mark.svg` mark, favicons, `og.png`, `hero.webp`/`hero.png`) are the **generated** copies
of the sources in [`/assets`](../../assets) — edit them there, not in `public/`, then rerun
`npm run build` (or `npm run sync:assets`). The web logo is the circular
`cloakdrop-mark.svg` family mark. It shares the macOS launcher's filled drop-shield and
download-arrow geometry while keeping the platform-appropriate circular web container.
The product section retains a real, transparent-background screenshot
of the app mid-download (WebP with a PNG fallback), and `og.png` is a 1200×630 share card.

## Air browser acceptance

After a production build, run preview on a fresh local port (8144 for this review),
then run from the repository root:

```bash
SITE_URL=http://127.0.0.1:8144 node scripts/test-air-site.mjs
SITE_URL=http://127.0.0.1:8144 node scripts/test-air-artwork.mjs
```

This test requires Chrome and an available `puppeteer-core` installation. Set
`CHROME_PATH` and `PUPPETEER_MODULE` (absolute module path or file URL) when those
are not locally resolvable. It adds no production dependency. `AIR_EVIDENCE_DIR`
selects the parent for a private temporary evidence directory; the printed path includes the full size/theme/root-font
matrix, open/closed menus, contrast, anchors, policy, 404, no-JS and metadata checks.
The artwork suite checks all four silhouettes, fixed download actions, pause/resume,
offscreen/Back restoration, live reduced-motion changes and static fallbacks. It
also validates desktop/laptop/mobile, both themes and enlarged text. The pixel
script is absent from privacy/404 routes; its source attribution ships at
`/pixel-art.LICENSE.txt`.
Actual Firefox/Safari review and physical/assistive limits are recorded separately
in [the Air validation record](../../docs/air/validation.md). Use a fresh port if an
older app's service worker controls a reused local origin; do not clear user data.

## Deploy (Cloudflare)

The existing host uses Cloudflare **Workers Builds** with a dashboard-managed Git integration;
there is no deployment workflow in this repository. Verify these settings on the existing
`cloakdrop` Worker:

1. **Repository:** `cloakyard/cloakdrop`; check the connected production branch.
2. **Root directory:** `apps/site`.
3. **Build command:** `npm run build` · **Deploy command:** `npx wrangler deploy`.
4. **Build watch include paths:** `apps/site/*`, `assets/*`, `scripts/sync-assets.mjs`,
   `PRIVACY.md`, `docs/air/*` (repository-relative). Include the policy and pinned
   artwork lifecycle because they are imported at build time.
   A Swift-only commit should not rebuild the site.

Production triggers and branch/PR previews depend on the dashboard configuration; do not assume
they are enabled from the local Wrangler file alone. A local build or dry run does not publish.

Observed October19,2026: production branch `main`, non-production builds enabled,
watch include `*`, root `apps/site`, and the commands above. The Air source on
`codex/air-refresh` was built and its version promoted to 100% production traffic.
Main/dev still need Air integration before a later main-triggered deployment.
See the [production deployment audit](../../docs/audits/2026-10-19-website-deployment.md).

### Manual deploy (optional)

```bash
npm run deploy                  # builds and publishes (requires Cloudflare authentication)
npx wrangler deploy --dry-run   # validate config without uploading
```

Run `npm run build` before a standalone dry run so `dist/` contains the current source.
`public/_headers` preserves revalidation and requests `no-transform` so Cloudflare
does not inject analytics or challenge scripts into the validated pages. Verify the
actual production headers and asset hashes after deployment. Keep
`package-lock.json` tracked. Check version compatibility and `npm audit` when updating packages;
the [dependency audit](../../docs/audits/2026-10-19-dependencies.md) records the TypeScript compatibility
pin and the resolved dependency graph.

## Custom domain — drop.cloakyard.com

In the Cloudflare dashboard, open the `cloakdrop` Worker → **Settings → Domains & Routes →
Add → Custom Domain** → `drop.cloakyard.com`. Cloudflare provisions DNS + TLS automatically.

**Prerequisite:** `cloakyard.com` must be a zone in the same Cloudflare account. If it isn't
yet, add the domain (move its nameservers to Cloudflare) first.
