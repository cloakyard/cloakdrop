# Shared brand assets

Single source of truth for CloakDrop's **shared** brand assets — the scalable logo, the
web icons/favicons, the social card, and product screenshots. Anything used in more than
one place (or that we don't want to duplicate in git) lives here and is **copied into each
consumer at build time** rather than committed twice.

```
assets/
├── logo/
│   ├── cloakdrop.svg          # scalable vector mark (gradient squircle + shield + arrow)
│   ├── icon.png               # app icon, 256×256 (web rendition)
│   ├── favicon.png            # 180×180
│   └── apple-touch-icon.png   # 512×512
├── social/
│   └── og.png                 # 1200×630 Open Graph / Twitter share card
└── screenshots/
    ├── hero.webp              # app hero screenshot, 2240w, transparent (primary)
    └── hero.png               # PNG fallback for the same
```

## How it's consumed

[`scripts/sync-assets.mjs`](../scripts/sync-assets.mjs) copies each file listed in its
`MANIFEST` into the apps that use it. It's a **pure `fs` copy** — no image tooling — so it
runs anywhere, including Cloudflare's Linux build container.

The brand site runs it automatically before every build (and dev start):

```jsonc
// apps/site/package.json
"sync:assets": "node ../../scripts/sync-assets.mjs",
"prebuild": "npm run sync:assets",   // npm runs this before `build`
"predev":   "npm run sync:assets"    // …and before `dev`
```

So on a fresh clone (or on Cloudflare) `npm run build` regenerates the site's copies from
here. You can also run it by hand from anywhere in the repo:

```bash
node scripts/sync-assets.mjs
```

The generated copies (e.g. `apps/site/public/logo.svg`, `…/hero.webp`) are **git-ignored** —
this folder is the only committed home for them. That's the whole point: no duplicated
binaries in version control.

## Updating an asset

1. Replace the file **here**, under `assets/…`.
2. Run `node scripts/sync-assets.mjs` (or just `npm run build` in `apps/site`).

That's it — every consumer picks it up. Renditions (extra sizes, WebP, the OG card) are
produced once by a human and committed here; the sync step only distributes them, it never
resizes or re-encodes.

## Adding a consumer

Add an entry to `MANIFEST` in `scripts/sync-assets.mjs`. `to` is an array, so one source
can fan out to several destinations:

```js
{ from: 'logo/cloakdrop.svg', to: ['apps/site/public/logo.svg', 'apps/other/assets/logo.svg'] }
```

## The macOS app icon

The glassy **app** icon is Xcode-managed and lives in its asset catalog —
`apps/macos/App/Resources/Assets.xcassets/AppIcon.appiconset/` (`icon_16.png` … `icon_1024.png`).
That's the master the raster web renditions above are exported from. It stays in the
catalog because Xcode needs the `Contents.json`-described renditions in place to build; it
isn't synced from here. When the app icon changes, re-export `logo/icon.png`,
`favicon.png`, `apple-touch-icon.png`, and rebuild the `social/og.png` card to match.
