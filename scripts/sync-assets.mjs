#!/usr/bin/env node
/**
 * sync-assets — copy shared brand assets from the repo-root /assets folder into each
 * app that consumes them. /assets is the single source of truth; the copies below are
 * generated (and git-ignored) so no logo, icon, or screenshot is duplicated in git.
 *
 * Pure fs copy — no image tooling — so it runs anywhere, including Cloudflare's Linux
 * build container. Renditions (sizes, WebP, the OG card) are produced once by a human
 * and committed under /assets; this script only distributes them.
 *
 * Runs automatically before `dev`/`build` in apps/site (see its package.json), and can
 * be invoked directly:  node scripts/sync-assets.mjs
 *
 * Add a consumer by adding an entry to MANIFEST — `to` accepts multiple destinations.
 */
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** source (relative to /assets) → one or more destinations (relative to repo root). */
const MANIFEST = [
  { from: 'logo/cloakdrop-mark.svg', to: ['apps/site/public/cloakdrop-mark.svg'] },
  { from: 'logo/favicon.svg', to: ['apps/site/public/icons/favicon.svg'] },
  { from: 'logo/icon.png', to: ['apps/site/public/icon.png'] },
  { from: 'logo/favicon.png', to: ['apps/site/public/favicon.png'] },
  { from: 'logo/apple-touch-icon.png', to: ['apps/site/public/apple-touch-icon.png'] },
  { from: 'social/og.png', to: ['apps/site/public/og.png'] },
  { from: 'screenshots/hero.webp', to: ['apps/site/public/hero.webp'] },
  { from: 'screenshots/hero.png', to: ['apps/site/public/hero.png'] },
];

let copied = 0;
let fresh = 0;
const missing = [];

for (const { from, to } of MANIFEST) {
  const src = resolve(ROOT, 'assets', from);
  if (!existsSync(src)) {
    missing.push(from);
    continue;
  }
  const bytes = readFileSync(src);
  for (const dest of to) {
    const out = resolve(ROOT, dest);
    const same = existsSync(out) && readFileSync(out).equals(bytes);
    if (same) {
      fresh++;
      continue;
    }
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, bytes);
    copied++;
    console.log(`  → ${dest}`);
  }
}

if (missing.length) {
  console.error(`\nsync-assets: missing sources under /assets:\n  - ${missing.join('\n  - ')}`);
  process.exit(1);
}

console.log(`sync-assets: ${copied} copied, ${fresh} up to date.`);
