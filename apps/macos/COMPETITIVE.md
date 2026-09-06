# CloakDrop capability inventory and product gaps

This document records the source tree checked on **6 September 2026**. It is not a release roadmap:
published beta builds can lag behind the source, and an idea listed here is not a delivery commitment.
The historical `COMPETITIVE.md` filename is retained, but this is a CloakDrop capability inventory.
It makes no current competitor feature, price or performance comparison; such comparisons require
fresh, dated evidence from the products concerned.

## Implemented in the current source

| Area | Capability | Boundary |
|---|---|---|
| Transfer | Adaptive and manual multi-segment downloads with bounded work stealing | Requires a known size and validated range support. Malformed intervals or oversized ranged bodies force a coherent single-stream restart, including during mirror failover. |
| Transfer | Pause, resume, relaunch recovery, retry, and network-loss recovery | Compatible staged bytes are reused; unknown-size retries reset staging. Relaunch tests do not establish physical power-loss durability. |
| Transfer | HTTP, HTTPS, FTP, and implicit-TLS FTPS | FTP segmentation requires successful `REST` capability probing; data reads have idle deadlines and validated passive endpoints. FTP/FTPS bypass HTTP proxy settings; explicit `AUTH TLS` is unsupported. |
| Transfer | Global and per-download limits, time-of-day profiles, queues, and recurrence | The aggregate limiter is shared across workers; each queue has its own active-download limit. |
| Transfer | Metalink mirrors and failover | Sources must pass range/size checks and available same-origin ETag checks; equal-length content across mirrors still needs a trusted checksum to establish identity. |
| Transfer | Origin-scoped HTTP forwarding/challenge authentication and cancellable bounded streams | Mirror/redirect requests strip sensitive headers across origins; challenge credentials separate origin and proxy scopes. HTTP task-object identities prevent callback collisions after proxy/session changes. Media request scoping has additional limits below. |
| Integrity | MD5, SHA-1, and SHA-256 verification with optional same-origin sibling discovery | Verification applies to ordinary-file staging data before publication when enabled. |
| Integrity | Local code-signature assessment | Limited to recognizable `.app` and `.dmg` code objects; it is not a notarization or Gatekeeper verdict. |
| Integrity | Quarantine stamping and an exportable Provenance Receipt | Both are configurable. A receipt records available evidence and can remain unverified when no trust signal exists. |
| Capture | Clipboard monitoring, drag and drop, batch/pattern parsing, Share Extension, Services item, and custom URL scheme | The link grabber handles one supplied page; it is not a recursive site crawler. Release App Group handoff requires signed entitlements. |
| Browser | Built-in WebKit browsing, download handoff, media sniffing, persistent logins, data wipe, and optional blocking rules | Blocking coverage depends on the selected rules and site. CloakDrop stores no separate browsing-history list. |
| Media | HLS/DASH planning, supported AES-128 decryption, quality selection, resumable segment transfer, and best-effort subtitle sidecars | Relative resources resolve against redirected manifest URLs. Manifest size and numeric expansion are bounded. Unsupported encryption is rejected; subtitle fetch/conversion failure does not fail an otherwise complete grab. |
| Media | Separate audio/language pairing and audio-only downloads | Required audio resolution fails preparation on error. Audio-only mode selects independently fetchable tracks, excluding URI-less in-band HLS renditions; ordinary video retains in-band defaults. |
| Media | Passthrough remux/mux through AVFoundation, with optional ffmpeg fallback | Assembly remains best effort: if all mux backends fail, a video-only result can still be published despite separately downloaded audio. No media is re-encoded. |
| Media | Optional yt-dlp page-to-format resolution, including supported audio-only pages | Parent HLS/DASH manifests, request headers and language groups are retained. The subprocess ignores external yt-dlp configuration/plugins and simulates metadata work; CloakDrop transfers the selected payload. Support depends on the bundled version, site, account and region. |
| Organize | Categories, smart filters, first-match routing rules, auto-sort, and duplicate warnings | Duplicate signals are URL, compatible ETag, or completed name plus size—not a content-addressed library. |
| Post-process | Native ZIP extraction and all-downloads-finished actions | ZIP support is STORE/DEFLATE only, without encryption. Actions are notify, quit, or run a named Shortcut. |
| Diagnostics | Manual Cloudflare/Ookla speed test and local lifetime statistics | Speed tests run only when the user starts one; statistics are local and resettable. |
| Platform | Native SwiftUI app, App Sandbox, Apple-silicon vendor helpers, macOS 26 minimum, menu bar, Dock progress, and localization | The app audit checked 494 source strings across ten translated locales, keyboard focus/selection, Reduce Motion, and light/dark appearance. It verified an ad-hoc Debug build, not notarized distribution. |

## Implemented behavior with remaining limits

- **Resource identity and durability:** size/range/available ETag checks cannot detect every equal-length
  content change without a trusted checksum. A response with neither length nor checksum cannot expose
  an intended-but-missing suffix at clean EOF. Checkpoints do not provide a transactional file/database
  durability barrier for sudden power loss.
- **Media compatibility:** plans currently share one header set across video, audio, keys and subtitles.
  Different per-resource/CDN authentication can fail. The metadata subprocess has no explicit seam for
  the app's manual proxy setting, although manifest and HTTP payload requests use the engine client.
  Expired signed playback URLs are not automatically refreshed on resume.
- **Live content:** HLS resolution takes a finite playlist snapshot. A detected live URL is not evidence
  of a complete live recorder; sliding-window refresh, recording controls and relaunch semantics are
  not implemented. DRM, site restrictions and upstream changes remain outside any compatibility guarantee.
- **Vendor currency:** GRDB 7.11.1, ffmpeg 9.0.1 and yt-dlp 2026.08.19 matched their latest stable releases
  when checked in the [dependency audit](../../docs/audits/2026-09-06-dependencies.md). The official
  yt-dlp distribution still contains older runtime components, including an outstanding OpenSSL security
  patch. Reproducible fetch/signature checks do not make every embedded library current or certify
  notarization; the proposed custom runtime remains separate, unimplemented work.

## Not implemented

- BitTorrent or peer-to-peer transfer.
- Recursive site crawling or full-site mirroring.
- Download-while-playing preview.
- Complete live-stream recording or automatic re-resolution of expired media URLs.
- Password-protected ZIP, RAR, or 7z extraction.
- Remote or mobile control.
- Premium-host, captcha, reconnect, or container-file ecosystems.
- General scripting, CLI, App Intents, Siri, or Spotlight actions. Running a chosen Shortcut after
  all downloads finish is the only current Shortcuts integration.
- Cloud file-reputation or community scoring.
- C2PA verification, speech transcription, generated subtitles, AI renaming, or AI organization.
- Content-hash library deduplication.
- Automatic application-update checks.

The premium-host/captcha ecosystem, cloud reputation, telemetry, and account-backed remote control
conflict with the current privacy and sandbox boundaries. Any future network surface or dependency
still requires an explicit product and privacy review; nothing above reserves or promises a future
implementation.

## Verification anchors

The [implementation audit](../../docs/audits/2026-09-06-overview.md) records a coordinated run of
**593 tests across 83 suites** (14 persistence, 314 model, 265 engine), plus a fresh app build/static
analysis and running-app verification. The GUI checks included a 64 MiB/eight-connection transfer
paused across relaunch with an independent SHA-256 match, closed-shadow-player capture, request-aware
preflight, checksum validation, keyboard selection, audio-only picking and light/dark appearance.
These are dated results, not universal network, locale, accessibility or performance certification.

- `DownloadEngineTests`: transfer, retry/resume, destination safety, HTTP/FTP loopback paths,
  checksums, archive extraction, remuxing, media transfer, Metalink, proxy, and speed-test behavior.
- `DownloadModelsTests`: parsers and pure policy for HLS/DASH, Metalink, capture/sniffing, rules,
  duplicate detection, schedules, naming, subtitles, signatures, and receipts.
- `DownloadPersistenceTests`: catalog/settings persistence and local statistics.
- [verify skill](../../.agents/skills/verify/SKILL.md): fresh Debug build plus running-app visual verification.
- [Engine audit](../../docs/audits/2026-09-06-engine.md): integrity/retry fixes, authentication scopes,
  cancellation and FTP evidence, with remaining durability and network coverage limits.
- [Media audit](../../docs/audits/2026-09-06-video.md): audio/manifest/collector regressions and dated
  public-page metadata smoke checks. Metadata success does not establish completed payload delivery.

When behavior changes, update this inventory in the same change and describe only code that is
present and tested.
