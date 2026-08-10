# CloakDrop capability inventory and product gaps

This document records what the current source tree does and does not do. It is not a release
roadmap: published beta builds can lag behind the source, and an idea listed here is not a delivery
commitment. Competitor feature matrices were removed because they age quickly and cannot serve as a
reliable source of truth for CloakDrop.

## Implemented in the current source

| Area | Capability | Boundary |
|---|---|---|
| Transfer | Adaptive and manual multi-segment downloads | Requires a known size and validated range support; otherwise the engine restarts coherently as one stream. |
| Transfer | Pause, resume, relaunch recovery, retry, and network-loss recovery | Resume reuses staged bytes only while local state and the remote representation remain compatible. |
| Transfer | HTTP, HTTPS, FTP, and implicit-TLS FTPS | FTP segmentation requires successful `REST` capability probing. FTP/FTPS bypass HTTP proxy settings. |
| Transfer | Global and per-download limits, time-of-day profiles, queues, and recurrence | The aggregate limiter is shared across workers; each queue has its own active-download limit. |
| Transfer | Metalink mirrors and failover | Sources must pass range and size checks; a supplied whole-file checksum remains the corruption backstop. |
| Integrity | MD5, SHA-1, and SHA-256 verification with optional same-origin sibling discovery | Verification applies to ordinary-file staging data before publication when enabled. |
| Integrity | Local code-signature assessment | Limited to recognizable `.app` and `.dmg` code objects; it is not a notarization or Gatekeeper verdict. |
| Integrity | Quarantine stamping and an exportable Provenance Receipt | Both are configurable. A receipt records available evidence and can remain unverified when no trust signal exists. |
| Capture | Clipboard monitoring, drag and drop, batch/pattern parsing, Share Extension, Services item, and custom URL scheme | The link grabber handles one supplied page; it is not a recursive site crawler. Release App Group handoff requires signed entitlements. |
| Browser | Built-in WebKit browsing, download handoff, media sniffing, persistent logins, data wipe, and optional blocking rules | Blocking coverage depends on the selected rules and site. CloakDrop stores no separate browsing-history list. |
| Media | HLS/DASH planning, supported AES-128 decryption, quality selection, resumable segment transfer, and best-effort subtitle sidecars | DRM streams are not downloaded. Subtitle fetch/conversion failure does not fail an otherwise complete grab. |
| Media | Passthrough remux/mux through AVFoundation, with optional ffmpeg fallback | If no backend supports split video/audio codecs, the video-only result is kept. No media is re-encoded. |
| Media | Optional yt-dlp page-to-format resolution | Supported sites depend on the bundled yt-dlp version and upstream changes. yt-dlp resolves metadata/URLs; CloakDrop transfers the selected payload. |
| Organize | Categories, smart filters, first-match routing rules, auto-sort, and duplicate warnings | Duplicate signals are URL, compatible ETag, or completed name plus size—not a content-addressed library. |
| Post-process | Native ZIP extraction and all-downloads-finished actions | ZIP support is STORE/DEFLATE only, without encryption. Actions are notify, quit, or run a named Shortcut. |
| Diagnostics | Manual Cloudflare/Ookla speed test and local lifetime statistics | Speed tests run only when the user starts one; statistics are local and resettable. |
| Platform | Native SwiftUI app, App Sandbox, Apple-silicon release build, macOS 26 minimum, menu bar, Dock progress, and localization | The source catalog currently covers English plus ten translated locales. |

## Not implemented

- BitTorrent or peer-to-peer transfer.
- Recursive site crawling or full-site mirroring.
- Download-while-playing preview.
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

- `DownloadEngineTests`: transfer, retry/resume, destination safety, HTTP/FTP loopback paths,
  checksums, archive extraction, remuxing, media transfer, Metalink, proxy, and speed-test behavior.
- `DownloadModelsTests`: parsers and pure policy for HLS/DASH, Metalink, capture/sniffing, rules,
  duplicate detection, schedules, naming, subtitles, signatures, and receipts.
- `DownloadPersistenceTests`: catalog/settings persistence and local statistics.
- `.agents/skills/verify/SKILL.md`: fresh Debug build plus running-app visual verification.

When behavior changes, update this inventory in the same change and describe only code that is
present and tested.
