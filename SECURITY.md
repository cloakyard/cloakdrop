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

- **No server, no account, no telemetry.** Nothing is uploaded and nothing phones home. Network
  egress happens only on your action: the URLs you choose to download, the sites you visit in the
  built-in browser (address-bar search, when enabled, sends the typed query to your chosen engine
  on Return), a proxy you configure, and the strictly manual speed test (Cloudflare by default,
  Ookla optional).
- **Sandboxed.** The app runs under the macOS App Sandbox with the hardened runtime. It accesses
  only the folders you point it at, via security-scoped bookmarks.
- **Local-only state.** Download history and settings are stored in a local SQLite database that
  you can export or delete at any time.
- **Credentials in the Keychain.** Saved per-site HTTP/FTP logins and the manual-proxy password are
  stored in the macOS **Keychain**, never in the plaintext settings database. The on-disk proxy
  password field is blanked and rehydrated into memory only at runtime.

### Risk areas

- **Third-party dependencies.** CloakDrop's only third-party Swift dependency is GRDB (SQLite).
  Two native command-line tools are also bundled as code-signed, sandboxed helper binaries:
  **ffmpeg** (stream-copy muxing) and **yt-dlp** (a read-only page→formats resolver). Both run
  in-sandbox as `inherit`-entitled children, only ever *read* or *transform* local data, and add
  no network egress of their own — the app's engine performs every download. Dependencies are kept
  minimal and reviewed before being added.
- **Downloaded content.** CloakDrop transfers files but does not execute them, and stamps the
  `com.apple.quarantine` flag on saved files so Gatekeeper vets them on first open. Always verify
  what you download; use the built-in checksum verification and the Provenance Receipt when an
  expected hash or signature is available.
- **Archive extraction.** Optional native ZIP auto-extraction is hardened against **Zip-Slip** path
  traversal and **decompression bombs** (compression-ratio + hard per-entry size caps), and runs
  only after the checksum verifies; each extracted file is quarantine-stamped. Only ZIP is handled
  natively — no third-party archive library is bundled.
- **macOS / system vulnerabilities** should be reported to Apple.

## Scope

This policy covers the CloakDrop application and the `DownloaderCore` package in this
repository. Issues in third-party dependencies should also be reported upstream.
