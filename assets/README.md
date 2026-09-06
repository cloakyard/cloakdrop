# Shared brand assets

Single source of truth for CloakDrop's **shared** brand assets — the scalable logo, the
web icons/favicons, the social card, and product screenshots. Anything used in more than
one place (or that we don't want to duplicate in git) lives here and is **copied into each
consumer at build time** rather than committed twice.

```
assets/
├── logo/
│   ├── cloakdrop.svg          # legacy flattened launcher artwork
│   ├── cloakdrop-mark.svg     # canonical 64×64 circular web mark
│   ├── favicon.svg            # circular mark with a favicon-specific title
│   ├── macos-layers/          # editable 1024×1024 sources imported by Icon Composer
│   ├── favicon.png            # circular web mark, 180×180
│   └── apple-touch-icon.png   # circular web mark, 512×512
├── social/
│   ├── og.html                # source for the card — the thing you edit
│   └── og.png                 # 1200×630 Open Graph / Twitter share card (rendered)
└── screenshots/
    ├── hero.webp              # clean native window alpha for the website (primary)
    ├── hero.png               # PNG fallback for the same
    ├── hero-readme.webp       # README rendition with a complete padded shadow
    └── hero-readme.png        # PNG fallback for the README rendition
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
here. You can also run it by hand from the repository root:

```bash
node scripts/sync-assets.mjs
```

The generated copies (e.g. `apps/site/public/cloakdrop-mark.svg`, `…/hero.webp`) are **git-ignored** —
this folder is the only committed home for them. That's the whole point: no duplicated
binaries in version control.

The root README references the `hero-readme` pair directly. The website pair contains the
clean native window alpha with no baked shadow; CSS can render that shadow without guessing
the corner geometry. The README pair reconstructs the shadow on a 72px transparent inset,
because GitHub cannot supply the same styling and would otherwise clip a tightly trimmed
shadow at the canvas edge.

## Updating an asset

1. Replace the file **here**, under `assets/…`.
2. From the repository root, run `node scripts/sync-assets.mjs` (or run `npm run build` in `apps/site/`).

That's it — every consumer picks it up. Renditions (extra sizes, WebP) are produced once by
a human and committed here; the sync step only distributes them, it never resizes or
re-encodes.

### Reproducible hero capture

Debug builds include a deterministic, read-only hero catalog. It renders the Ubuntu transfer and
the five completed reference rows without opening the user's database, creating partial files, or
making a network request. From the repository root, after a fresh Debug build:

```bash
open -n apps/macos/build/Verify/Build/Products/Debug/CloakDrop.app --args --hero-fixture
```

The fixture is compiled only when `DEBUG` is set. Capture the main window at 1097 × 678 points
(2194 × 1356 Retina pixels), then produce the padded README rendition on a 2338 × 1500 transparent
canvas. Keep the four files in `assets/screenshots/` synchronized before running the asset sync.

Debug also accepts `--verify-dark-appearance` to inspect native dark materials without changing the
system appearance. Keep audit screenshots in [`docs/audits/images/`](../docs/audits/images); do not
replace the canonical hero with temporary test records or a personal download catalog. The fixture
is illustrative, not a measured throughput benchmark. See the
[verification guide](../.agents/skills/verify/SKILL.md) for app checks.

## The social card

`social/og.png` is **rendered, not drawn** — edit [`social/og.html`](social/og.html) and run from the repository root:

```bash
scripts/make-og.sh            # headless Chrome screenshots og.html → og.png (1200×630)
node scripts/sync-assets.mjs  # …then distribute it
```

The card borrows its fonts, colours and tracking straight from the site's design system
(`apps/site/src/styles/global.css`), so the two stay in step and a copy change costs a
re-render rather than a redraw.

## Adding a consumer

Add an entry to `MANIFEST` in `scripts/sync-assets.mjs`. `to` is an array, so one source
can fan out to several destinations:

```js
{ from: 'logo/cloakdrop-mark.svg', to: ['apps/site/public/cloakdrop-mark.svg'] }
```

## Web mark and macOS app icon

The website uses `logo/cloakdrop-mark.svg`, a circular `64 × 64` Cloakyard
family mark. Its filled drop-shield and download arrow use the exact same paths
as the macOS foreground layers; only the outer container differs. The web mark
keeps the family circle, while macOS supplies its native launcher mask.

The macOS launcher source of truth is
`apps/macos/App/Resources/AppIcon.icon`, a native Icon Composer document. Its
background, drop-shield, and arrow come from `logo/macos-layers/`; Xcode applies the
platform mask and compiles the layered Liquid Glass material for Default, Dark,
and Mono appearances. `apps/macos/scripts/generate_app_icon.swift` uses Icon
Composer's `ictool` to export the flattened `AboutAppIcon.imageset` copies and
keep the conventional `AppIcon.appiconset` PNG fallbacks visually aligned:

```bash
cd apps/macos && swift scripts/generate_app_icon.swift    # needs Xcode 26.4+
```

When the shared pictogram changes, update the identical paths in
`logo/cloakdrop-mark.svg`, `logo/favicon.svg`, `logo/macos-layers/`, and
`AppIcon.icon`, then refresh the generated web and About artwork. Keep the web
mark circular and let Icon Composer retain the native macOS shape.
