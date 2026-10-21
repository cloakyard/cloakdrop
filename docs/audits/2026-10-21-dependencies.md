# October 21, 2026 — website rollout dependencies

Updated Astro to 7.4.1, Astro Check to 0.9.11 and Wrangler to 4.151.3.
The project and CI now pin npm 12.2.0; the Node engine range matches npm's
supported 22.22.2 / 24.15.0 / 26+ lines. Current checkout/setup-node action
pins remain unchanged. The lockfile was installed cleanly and its tree is valid.
Portable Air study/shader bundles were regenerated with the family's upgraded
React 19.3.1 / Vite+ 1.3.0 toolchain and synchronized with matching hashes/licenses.
No native source, helper, app UI or RC download artifact changed.

The current upstream GRDB 7.11.1, FFmpeg 9.0.2 and yt-dlp 2026.08.19 remain
pinned. Primary sources: [GRDB](https://github.com/groue/GRDB.swift/releases),
[FFmpeg](https://ffmpeg.org/download.html), [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases).
The maintainer-approved official-bundle runtime exception remains unchanged;
embedded Python/OpenSSL and other frozen libraries are not claimed latest.
TypeScript stays at 6.0.3 because [Astro Check 0.9.11](https://registry.npmjs.org/@astrojs/check/0.9.11)
only supports TypeScript 5/6. Reassess when its peer range includes 7.

Clean npm install/tree, zero audit vulnerabilities, zero Astro diagnostics,
three-route build, Wrangler dry run, 20 inventory entries and 18 portability
assertions pass. Browser acceptance: 432 layouts, 34 journeys, 328 neutral link
states and 116 keyboard checks; actual GPU lifecycle and six fallback profiles
pass. Desktop/laptop/phone light and dark screenshots were visually inspected.
Native inputs are unchanged; earlier 626-test/Debug/Release results are in the
[RC dependency audit](2026-10-19-dependencies.md), not new runs in this piece.

[Evidence and build hashes](../air/evidence/dependencies-2026-10-21.json).
Rollout remains prepared locally; no push/deployment. RC signing/notarization,
physical-device and assistive acceptance limitations remain as documented.

Final compatible transitive refresh updates Vite 8.3.5, Undici 8.12.3,
fast-uri 3.1.9, tinyps 0.5.1 and Shiki's TextMate 10.1.0. A second clean
install/check/build/audit passes. Every executable and visible build asset is
byte-identical to the inspected build; only the synchronized shader license
inventory changes. The existing responsive/feature proof therefore remains valid.
