// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Fully static output (Astro's default) — the marketing site ships as plain HTML/CSS
// and is served from Cloudflare Workers static assets (see wrangler.jsonc). No SSR
// adapter and no client-side JS framework: keep it zero-runtime.
export default defineConfig({
  site: 'https://drop.cloakyard.com',
  integrations: [sitemap()],
  build: { format: 'directory' },
  compressHTML: true,
  prefetch: false,
});
