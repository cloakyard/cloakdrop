# CloakDrop brand site

The marketing site for **CloakDrop**, hosted at **[drop.cloakyard.com](https://drop.cloakyard.com)**.

- **Stack:** [Astro](https://astro.build) 7 — fully static output, zero client-side JS.
- **Host:** Cloudflare **Workers static assets** (`wrangler.jsonc` → serves `dist/` from the edge).
- **Design:** native-macOS aesthetic on CloakDrop's own accent (`#5B5BDE` / `#827EEA`); follows the OS light/dark theme via `prefers-color-scheme`.

Part of the CloakDrop monorepo — the macOS app lives in [`../macos`](../macos).

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
├── public/                 # favicon, icons, og.png, hero.png (real app screenshot), robots.txt
└── src/
    ├── data/site.ts        # ← all copy, links, features, stats (single source of truth)
    ├── layouts/BaseLayout  # <head>, SEO/OG, JSON-LD, theme-color
    ├── components/         # Header · Hero · Features · Privacy · Suite · Footer · Icon
    ├── pages/index.astro   # the one page
    └── styles/global.css   # design tokens (light/dark) + shared primitives
```

Edit copy in [`src/data/site.ts`](src/data/site.ts); components read from it. The hero image
(`public/hero.png`) is a real screenshot of the app mid-download — regenerate it from the app
if the UI changes. The favicon / touch icon / logo use the **glassified** (Liquid Glass) app
icon as macOS Tahoe renders it, and `public/og.png` is a 1200×630 branded share card built
from it — regenerate both from a fresh app build if the icon changes.

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
