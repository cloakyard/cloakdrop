# Security Policy

CloakDrop is a privacy-first download manager. We take security and privacy seriously and
appreciate responsible disclosure.

## Supported Versions

Security fixes target the latest release, including the current beta. Older versions do not
receive backports. Install updates manually from [GitHub Releases](https://github.com/cloakyard/cloakdrop/releases);
the app does not check for updates automatically. Fixes in the repository may not yet be included
in a published installer.

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

Remove passwords, session cookies, signed URL tokens, and unrelated personal data from examples
and logs. If exposure of that data is the issue, describe it in the private report rather than
posting the affected download record publicly.

What to expect:

- The report will be triaged privately, and maintainers will coordinate reproduction and disclosure
  with you as availability permits.
- Credit in the release notes when a fix ships, unless you prefer to remain anonymous.

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
- **Request scope.** The HTTP engine removes `Authorization`, `Proxy-Authorization`, and `Cookie`
  headers when following a redirect or selecting a mirror on another origin (scheme, host, or port).
  HTTP authentication challenges use credentials scoped to the origin or configured proxy.
  This does not strip arbitrary custom headers or secrets embedded in URLs. Browser video
  resolution can provide yt-dlp with a temporary cookie jar that preserves cookie domain/path
  scope; flattened page cookies are not forwarded to a different media host by the app.
- **Proxy limits.** The download proxy setting is not an app-wide traffic tunnel. HTTP transfers
  and speed tests use it; the browser mirrors manual routing and otherwise uses system routing.
  FTP/FTPS connects directly, and the app does not pass its proxy setting to yt-dlp. See the
  [privacy policy](PRIVACY.md#network-activity) for the complete request surface.

### Signing and the current beta

The current beta is locally signed, but is **not Developer ID-signed or notarized by Apple**.
A valid local code signature does not establish an Apple-verified publisher or notarization.
For an official download you trust, follow [Apple's opening guidance](https://support.apple.com/en-us/102445)
and the [installer guide](apps/macos/scripts/dmg/ReadMe.txt). We will consider joining Apple's paid
Developer Program for notarization as demand grows; no notarized release date is promised.

### Risk areas

- **Third-party dependencies.** CloakDrop's only third-party Swift dependency is GRDB (SQLite).
  Release builds can also bundle two native command-line tools as code-signed, sandboxed helpers:
  **ffmpeg** (network-free stream-copy muxing) and **yt-dlp** (a page→formats resolver). Both run
  in-sandbox as `inherit`-entitled children. ffmpeg transforms local data only; yt-dlp may contact a
  user-submitted video page and related endpoints to resolve metadata/media URLs, but it does not
  transfer the selected media payload—the app's engine does. Its invocation ignores user
  configuration, disables plugin directories and persistent caches, and uses simulation mode.
  Vendor scripts pin upstream versions and SHA-256 hashes, validate prepared helpers before
  replacing the installed copies, and re-sign them for the app. These checks are separate from
  upstream signature verification and Apple notarization.
- **Known dependency follow-up.** The [6 September 2026 dependency audit](docs/audits/2026-09-06-dependencies.md)
  records exact versions, source provenance, and validation. Although GRDB, ffmpeg and yt-dlp match
  their audited latest stable releases on that date, the official yt-dlp runtime includes older components:
  notably OpenSSL 3.5.7 with a newer security patch available. The checked nightly/master bundles
  retain that runtime. A separately built, updated runtime remains pending approval and validation;
  this project does not claim that every bundled library is current or vulnerability-free.
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

This policy covers the CloakDrop application, the `DownloaderCore` package, bundled helpers,
vendor/build scripts, and brand site in this repository. Issues in third-party dependencies
should also be reported upstream; let us know privately when CloakDrop is affected.
