# Website dependency and privacy audit — 14 November 2026

Upgrade Astro to 7.4.12, sitemap to 3.7.5 and Wrangler to 4.162.0 with a refreshed lockfile. Retain TypeScript 6.0.3 within the current Astro checker's supported peer range. Add the website-hosting/external-service disclosure separately from native behavior, and derive the app policy revision from its maintained Markdown. Astro check/build and Worker dry-run pass; npm audit has zero findings. The website has no service worker and does not show a PWA update notice. Native runtime pins and the user-approved official yt-dlp exception are documented separately in the native dev audit; this website change does not release native features.

All applicable public/secondary pages, editor controls, dialogs/notices and motion were compared across phone, tablet, laptop and desktop in light/dark. Air 1.7.3 records one maintained privacy body/date/lead; the shared notice and motion implementation is unchanged. The canonical family audit owns the complete per-view coverage ledger, limitations and portable evidence. Raw receipts remain in `/Users/sumitsahoo/Developer/.air-review-2026-11-14/evidence`.

Source checks, types/build, package audit, Knip and standalone Air conformance/portability pass. No unused application code was detected. Physical-device, keyboard/IME, actual zoom and spoken-assistive acceptance remain open. A software layout audit does not close those gates.

Family record: [maintenance audit](https://github.com/cloakyard/cloakyard/blob/main/docs/air/maintenance-audit-2026-11-14.md).
