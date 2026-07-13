# CloakDrop brand site

The marketing site for **CloakDrop**, hosted at **[drop.cloakyard.com](https://drop.cloakyard.com)**.

- **Stack:** [Astro](https://astro.build) 7 — fully static output, zero client-side JS.
- **Host:** Cloudflare **Workers static assets** (`wrangler.jsonc` → serves `dist/` from the edge).
- **Design:** editorial / magazine layout — numbered sections, hairline rules, self-hosted **Archivo** (heavy display) + **JetBrains Mono** (labels & data) on CloakDrop's deep-ocean accent (`#2A7B9B`). Follows the OS light/dark theme via `prefers-color-scheme`. Fonts are self-hosted (no Google Fonts request) to keep the privacy story intact.

Part of the CloakDrop monorepo — the macOS app lives in [`../macos`](../macos). Shared brand
assets (logo, favicons, OG card, hero screenshot) are **not** stored here — they live in the
repo-root [`/assets`](../../assets) folder and are copied into `public/` at build time by
`scripts/sync-assets.mjs` (runs automatically via the `prebuild` npm hook). See
[`/assets/README.md`](../../assets/README.md).

## Develop

```bash
cd apps/site
npm install          # one-time
npm run dev          # http://localhost:4321 (hot reload)
```

## Build & check

```bash
npm run build        # → dist/ (static)
npm run preview      # serve the built dist/ locally
npm run check        # astro type-check (0 errors expected)
```

## Structure

```
apps/site/
├── astro.config.mjs        # static config + sitemap; site = drop.cloakyard.com
├── wrangler.jsonc          # Cloudflare Workers static-assets (serves ./dist)
├── public/
│   ├── fonts/              # self-hosted Archivo + JetBrains Mono (variable woff2) — tracked
│   ├── robots.txt          # tracked
│   └── logo.svg, *.png …   # brand assets — GENERATED from /assets by sync-assets (git-ignored)
└── src/
    ├── data/site.ts        # ← all copy, links, section content (single source of truth)
    ├── layouts/BaseLayout  # <head>, SEO/OG, JSON-LD, theme-color, font preloads
    ├── components/         # Header · Hero · SpecStrip · Engine · Provenance · Capture ·
    │                       #   Details · Privacy · UnderTheHood · Suite · Footer
    │                       #   + shared: Icon · Kicker (numbered label) · Brand (logo lockup)
    ├── pages/index.astro   # the one page — composes the sections in order
    └── styles/global.css   # @font-face + design tokens (light/dark) + shared primitives
```

Edit copy in [`src/data/site.ts`](src/data/site.ts); components read from it. Brand assets
(the `logo.svg` mark, favicons, `og.png`, `hero.webp`/`hero.png`) are the **generated** copies
of the sources in [`/assets`](../../assets) — edit them there, not in `public/`, then rerun
`npm run build` (or `npm run sync:assets`). The logo is a scalable SVG mark echoing the
**glassified** (Liquid Glass) app icon; the hero is a real, transparent-background screenshot
of the app mid-download (WebP with a PNG fallback), and `og.png` is a 1200×630 share card —
regenerate all three to match if the app UI or icon changes.

## Deploy (Cloudflare)

Deployment is handled by Cloudflare's **Workers Builds** Git integration from the dashboard —
the same setup as the other Cloakyard sites (e.g. cloakpdf). No workflow lives in the repo;
Cloudflare builds and deploys on every push to the connected branch.

The app repo **is** the Git repo Cloudflare deploys from — a monorepo just needs the build
pointed at this subdirectory:

1. Cloudflare dashboard → **Workers & Pages → Create → Connect to Git** → pick
   `cloakyard/cloakdrop`. *(This is the "it asks for a git repo" step — the existing repo
   already satisfies it.)*
2. **Root directory:** `apps/site`
3. **Build command:** `npm run build` · **Deploy command:** `npx wrangler deploy`
4. **Build watch paths:** `apps/site/*` — so a Swift-only commit never rebuilds the site.

Push to the connected branch → production deploy; pull requests → preview URLs.

### Manual deploy (optional)

```bash
npm run deploy                  # astro build && wrangler deploy  (needs `wrangler login`)
npx wrangler deploy --dry-run   # validate config without uploading
```

## Custom domain — drop.cloakyard.com

In the Cloudflare dashboard, open the `cloakdrop-site` Worker → **Settings → Domains & Routes →
Add → Custom Domain** → `drop.cloakyard.com`. Cloudflare provisions DNS + TLS automatically.

**Prerequisite:** `cloakyard.com` must be a zone in the same Cloudflare account. If it isn't
yet, add the domain (move its nameservers to Cloudflare) first.
