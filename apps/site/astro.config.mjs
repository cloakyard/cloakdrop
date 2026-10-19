// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { copyFile, readFile, readdir } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';

/** @type {import('astro').AstroIntegration} */
const airAssets = {
  name: 'air-landing-assets',
  hooks: {
    'astro:build:done': async ({ dir }) => {
      const assets = new URL('_astro/', dir);
      const shaders = (await readdir(assets)).filter((name) => /^air-light-shader\..*\.js$/.test(name));
      if (shaders.length !== 1) throw new Error('Expected one separate lazy Air shader');
      if (gzipSync(await readFile(new URL(shaders[0], assets))).byteLength > 350_000)
        throw new Error('Lazy Air shader exceeds 350 kB gzip');
      await copyFile(
        new URL('../../docs/air/assets/THIRD_PARTY_LICENSES.txt', import.meta.url),
        new URL('air-light.LICENSE.txt', dir),
      );
    },
  },
};

// Fully static output (Astro's default) — the marketing site ships as plain HTML/CSS
// and is served from Cloudflare Workers static assets (see wrangler.jsonc). No SSR
// adapter or client-side framework. The optional artwork renderer loads lazily.
export default defineConfig({
  site: 'https://drop.cloakyard.com',
  integrations: [sitemap(), airAssets],
  build: { format: 'directory' },
  compressHTML: true,
  prefetch: false,
});
