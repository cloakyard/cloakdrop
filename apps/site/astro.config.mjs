// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Fully static output (Astro's default) — the marketing site ships as plain HTML/CSS
// and is served from Cloudflare Workers static assets (see wrangler.jsonc). No SSR
// adapter or client-side framework; only small first-party interaction scripts ship.
export default defineConfig({
  site: 'https://drop.cloakyard.com',
  integrations: [sitemap()],
  build: { format: 'directory' },
  compressHTML: true,
  prefetch: false,
});
