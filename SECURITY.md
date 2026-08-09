# Security Policy

CloakDrop is a privacy-first download manager. We take security and privacy seriously and
appreciate responsible disclosure.

## Supported Versions

Only the latest released version receives security updates.

| Version | Supported          |
| ------- | ------------------ |
| latest  | :white_check_mark: |
| older   | :x:                |

## Reporting a Vulnerability

**Please do not open a public issue for security vulnerabilities.**

Instead, report it privately through GitHub Security Advisories:

➡️ **https://github.com/cloakyard/cloakdrop/security/advisories/new**

Please include:

- A description of the vulnerability and its potential impact.
- Clear steps to reproduce (a proof of concept if possible).
- The affected version / commit and your environment (macOS version).

What to expect:

- **Acknowledgement within 48 hours.**
- **A status update within 7 days.**
- Credit in the release notes when the fix ships, unless you prefer to remain anonymous.

## Security Model

CloakDrop is a native, sandboxed macOS app designed to minimize attack surface:

- **No CloakDrop server, account, or telemetry.** Network activity is limited to configured download
  work (including redirects, mirrors, retries, schedules/resume, and optional same-origin checksum
  discovery); yt-dlp metadata resolution for a video page you submit; pages and subresources loaded
  in the built-in browser; an address-bar query sent to your chosen search engine on Return; a proxy
  you configure; a speed test you start (Cloudflare default, Ookla optional); and an optional browser
  blocklist you explicitly select or update. There are no project analytics or update pings.
- **Sandboxed.** The app runs under the macOS App Sandbox with the hardened runtime. It accesses its
  containers, the standard Downloads folder covered by its entitlement, and destinations you select
  via security-scoped bookmarks.
- **Local-only state.** Download history and settings are stored in a local SQLite database. The app
  provides controls to remove download records, clear completed records, and reset local statistics.
- **Credential boundaries.** Remembered per-site HTTP/FTP logins and the manual-proxy password are
  stored in the macOS **Keychain**. The on-disk proxy password field is blanked and rehydrated into
  memory only at runtime. A credential attached to one download is also stored in that local,
  user-deletable download record so the transfer can resume.

### Risk areas

- **Third-party dependencies.** CloakDrop's only third-party Swift dependency is GRDB (SQLite).
  Two native command-line tools are also bundled as code-signed, sandboxed helper binaries:
  **ffmpeg** (network-free stream-copy muxing) and **yt-dlp** (a page→formats resolver). Both run
  in-sandbox as `inherit`-entitled children. ffmpeg transforms local data only; yt-dlp may contact a
  user-submitted video page and related endpoints to resolve metadata/media URLs, but it does not
  transfer the selected media payload—the app's engine does. Dependencies are kept minimal and
  reviewed before being added.
- **Downloaded content.** CloakDrop transfers files but does not execute them. Its default-on
  quarantine setting stamps `com.apple.quarantine` on saved files so Gatekeeper vets them on first
  open. Always verify what you download; use the built-in checksum verification and the Provenance
  Receipt when an expected hash or signature is available.
- **Archive extraction.** Optional native ZIP auto-extraction is hardened against **Zip-Slip** path
  traversal and **decompression bombs** (compression-ratio + hard per-entry size caps). It never runs
  after a known checksum mismatch; when checksum verification is enabled and an expected checksum is
  available, verification runs first. Extracted files receive quarantine when that setting is enabled.
  Only ZIP is handled natively—no third-party archive library is bundled.
- **macOS / system vulnerabilities** should be reported to Apple.

## Scope

This policy covers the CloakDrop application and the `DownloaderCore` package in this
repository. Issues in third-party dependencies should also be reported upstream.
