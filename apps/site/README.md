# CloakDrop brand site

The marketing site for **CloakDrop**, hosted at **[drop.cloakyard.com](https://drop.cloakyard.com)**.

- **Stack:** [Astro](https://astro.build) 7 — fully static output, with a small first-party
  script for progressive motion and the interactive transfer demonstration.
- **Host:** Cloudflare **Workers static assets** (`wrangler.jsonc` → serves `dist/` from the edge).
- **Design:** editorial / magazine layout — numbered sections, hairline rules, self-hosted **Archivo** (heavy display) + **JetBrains Mono** (labels & data) on CloakDrop's deep-ocean accent (`#2A7B9B`). Follows the OS light/dark theme via `prefers-color-scheme`. Fonts are self-hosted (no Google Fonts request) to keep the privacy story intact.

Part of the CloakDrop monorepo — the macOS app lives in [`../macos`](../macos). Shared brand
assets (logo, favicons, OG card, hero screenshot) live in the repo-root
[`/assets`](../../assets) folder and are copied into `public/` at build time by the root
`scripts/sync-assets.mjs` script (run automatically by the `prebuild` hook). See
[`/assets/README.md`](../../assets/README.md).

The landing-page copy describes the current source tree. Published beta builds can lag behind it;
GitHub Releases remains the source of truth for the contents and installation status of each build.
The compact install note documents the locally signed, non-notarized beta and Apple’s current
Privacy & Security → Open Anyway flow; keep it aligned with the DMG install guide.

The landing page keeps a real app screenshot, three short interactive product chapters, an
open-source/privacy band, and a download panel. Motion is finite, respects reduced motion, and
never starts a network request. Without JavaScript, the product chapters remain readable.

## Develop

Requires **Node 22.12.0 or later** and npm. Start from the repository root; the remaining
commands in this guide run inside `apps/site/`.

```bash
cd apps/site
npm ci               # reproducible install from package-lock.json
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
keyboard navigation (including chapter tabs and the mobile menu), reduced motion, enlarged text
and the no-JavaScript fallback. The transfer demonstration is illustrative; it performs no real
download or throughput measurement. See the [website audit](../../docs/audits/2026-09-06-website.md)
for the latest recorded checks and screenshots.

## Structure

```
apps/site/
├── astro.config.mjs        # static config + sitemap; site = drop.cloakyard.com
├── wrangler.jsonc          # Cloudflare Workers static-assets (serves ./dist)
├── public/
│   ├── fonts/              # self-hosted Archivo + JetBrains Mono (variable woff2) — tracked
│   ├── robots.txt          # tracked
│   └── cloakdrop-mark.svg, icons/favicon.svg, *.png …
│                           # brand assets — GENERATED from /assets by sync-assets (git-ignored)
└── src/
    ├── data/site.ts        # shared product copy, links, and structured section content
    ├── layouts/BaseLayout  # <head>, SEO/OG, JSON-LD, theme-color, font preloads
    ├── components/         # Landing sections plus shared Brand · Icon · Kicker components
    ├── pages/index.astro   # landing page — composes the sections in order
    ├── pages/privacy.astro # renders the repo-root privacy policy for the web
    ├── pages/404.astro     # static not-found page used by Cloudflare
    ├── scripts/motion.ts   # finite reveals, hero arrival, and navigation
    ├── scripts/transferDemo.ts # keyboard tabs + user-started relaunch illustration
    └── styles/global.css   # @font-face + design tokens (light/dark) + shared primitives
```

Edit shared product copy and links in [`src/data/site.ts`](src/data/site.ts). Labels and
annotations that belong to a specific visual demonstration live beside that component's markup.
The privacy page imports [`PRIVACY.md`](../../PRIVACY.md); update its displayed date in
`src/pages/privacy.astro` when the source policy changes; sync the native Privacy settings page
and its translations too. Keep installation steps aligned with the
[README](../../README.md#download-and-install) and [DMG guide](../macos/scripts/dmg/ReadMe.txt).
Brand assets
(the `cloakdrop-mark.svg` mark, favicons, `og.png`, `hero.webp`/`hero.png`) are the **generated** copies
of the sources in [`/assets`](../../assets) — edit them there, not in `public/`, then rerun
`npm run build` (or `npm run sync:assets`). The web logo is the circular
`cloakdrop-mark.svg` family mark. It shares the macOS launcher's filled drop-shield and
download-arrow geometry while keeping the platform-appropriate circular web container.
The hero is a real, transparent-background screenshot
of the app mid-download (WebP with a PNG fallback), and `og.png` is a 1200×630 share card.

## Deploy (Cloudflare)

The existing host uses Cloudflare **Workers Builds** with a dashboard-managed Git integration;
there is no deployment workflow in this repository. Verify these settings on the existing
`cloakdrop` Worker:

1. **Repository:** `cloakyard/cloakdrop`; check the connected production branch.
2. **Root directory:** `apps/site`.
3. **Build command:** `npm run build` · **Deploy command:** `npx wrangler deploy`.
4. **Build watch include paths:** `apps/site/*`, `assets/*`, `scripts/sync-assets.mjs`,
   `PRIVACY.md` (repository-relative). Include the policy because it is rendered at build time.
   A Swift-only commit should not rebuild the site.

Production triggers and branch/PR previews depend on the dashboard configuration; do not assume
they are enabled from the local Wrangler file alone. A local build or dry run does not publish.

### Manual deploy (optional)

```bash
npm run deploy                  # builds and publishes (requires Cloudflare authentication)
npx wrangler deploy --dry-run   # validate config without uploading
```

Run `npm run build` before a standalone dry run so `dist/` contains the current source. Keep
`package-lock.json` tracked. Check version compatibility and `npm audit` when updating packages;
the [dependency audit](../../docs/audits/2026-09-06-dependencies.md) records the TypeScript compatibility
pin and the resolved dependency graph.

## Custom domain — drop.cloakyard.com

In the Cloudflare dashboard, open the `cloakdrop` Worker → **Settings → Domains & Routes →
Add → Custom Domain** → `drop.cloakyard.com`. Cloudflare provisions DNS + TLS automatically.

**Prerequisite:** `cloakyard.com` must be a zone in the same Cloudflare account. If it isn't
yet, add the domain (move its nameservers to Cloudflare) first.
