# CloakDrop App Privacy Policy

_Last updated: September 6, 2026_

CloakDrop is a free, open-source download manager for macOS. This policy describes the data the app keeps on your Mac, the network activity its features can create, and the controls available to you.

This policy covers the CloakDrop app. Websites, search engines, proxy operators, speed-test providers, blocklist hosts, GitHub, and other services you choose to contact have their own privacy practices.

## Privacy at a glance

- CloakDrop has no accounts, advertising, analytics SDK, telemetry, or automatic update checks.
- CloakDrop does not upload crash reports or your app activity to the CloakDrop project.
- Download records and settings stay in local app storage; request data is sent only as needed for the network activity described below.
- Network activity is limited to downloads and features you initiate or configure, including automatic behavior you enable or leave enabled.

## Data stored on your Mac

CloakDrop needs local state to resume transfers and provide its features. Its sandboxed local database can contain:

- Download URLs and mirrors, destination paths and security-scoped bookmarks, progress, status, and history.
- App settings, queues, rules, schedules, and download statistics.
- Per-download request headers, which can include a referrer or cookies.
- HTTP or FTP credentials entered for a particular download.
- Checksums, signature assessments, and provenance receipts generated for completed downloads.

Website credentials that you choose to remember and manual-proxy secrets are also saved in the macOS Keychain. A credential used by an individual download can additionally be present in that download's local database record so the transfer can resume.

The built-in browser uses WebKit's local website-data store for cookies, caches, and other site data. CloakDrop does not maintain a browsing-history list.

When resolving a video page from the browser, CloakDrop can export the browser's cookie store to a private temporary file for yt-dlp. The file retains cookie domain and path rules so the helper can use logins across the site's service endpoints. CloakDrop removes that file when resolution finishes. Cookies or headers attached to the selected download can remain in its local record for resume.

None of this local app data is sent to the CloakDrop project for analytics, profiling, or telemetry.

## Network activity

CloakDrop can make the following network requests:

- **Downloads:** probes and transfers for URLs you add, including redirects, mirrors, retries, scheduled or repeating transfers, and downloads resumed automatically after launch when that setting is enabled.
- **Checksum discovery:** when automatic checksum verification and discovery are enabled, CloakDrop tries same-origin sibling files ending in `.sha256`, `.sha1`, and `.md5` after the bytes arrive and before publishing an ordinary download's final file. This setting is enabled by default and can be turned off in Settings.
- **Video-page resolution:** when a build includes the optional yt-dlp helper and you submit a supported video-page URL, the helper contacts that page and related service endpoints to resolve metadata and media-format URLs.
- **Built-in browser:** WebKit loads pages you visit and the resources those pages request, which can include third-party images, scripts, frames, media, ads, or trackers. The optional blocker can reduce some of those requests.
- **Address-bar search:** if search is enabled, the query is sent to your selected search engine only when you press Return.
- **Proxies:** HTTP-based downloads and speed tests use your macOS system proxy by default, or direct/manual routing if you choose it. Manual routing is also mirrored into the built-in browser; other browser modes follow the system configuration, including when downloads are set to direct. The native FTP/FTPS client connects directly. The app's proxy setting is not passed to yt-dlp, whose routing depends on its runtime and environment. This setting does not route all app traffic through one proxy.
- **Speed tests:** Cloudflare or Ookla is contacted only while a speed test you started is running.
- **Optional blocklists:** an open-source ad-blocking list is fetched only when you select it or press **Update Now**, never on a timer or at launch.

There are no analytics beacons, advertising calls injected by CloakDrop, update pings, or other phone-home requests.

## What contacted services can see

Servers and proxies you choose to contact can receive ordinary request information needed to provide the service. Depending on the request, that can include your IP address, the requested URL or resource, request headers, and cookies or credentials applicable to that host. The CloakDrop project does not receive or retain a separate copy of that information.

The HTTP download engine removes `Authorization`, `Proxy-Authorization`, and `Cookie` headers when a redirect or mirror changes origin (scheme, host, or port). It also scopes HTTP authentication challenges to the origin or configured proxy. Other custom headers and tokens inside a URL are still part of the configured request. For video resolution, yt-dlp receives the cookie jar or cookie header supplied for that operation; the app prevents a flattened page cookie header from being carried into a selected media download on a different host.

## Bundled tools

CloakDrop release builds can include two open-source command-line helpers; source builds still run
without either helper, with the related media capability unavailable:

- **ffmpeg** combines or repackages local media with stream copy, without re-encoding. Its build disables network protocols; only local file, pipe, and file-descriptor protocols are enabled.
- **yt-dlp** contacts a video page and related service endpoints to resolve metadata and available formats, but it does not download the selected media payload. The app ignores external yt-dlp configuration, disables plugin directories and persistent caches, and explicitly requests simulation mode.

CloakDrop's own download engine transfers the files and media you select, preserving its pause, resume, persistence, and sandbox behavior.

## Sandbox and file access

CloakDrop runs inside the macOS App Sandbox. It can access its own app and App Group containers, the standard Downloads folder allowed by its entitlement, and locations you explicitly select. Access to user-selected destinations is remembered with security-scoped bookmarks; CloakDrop cannot freely browse the rest of your disk.

## Your controls

CloakDrop provides controls to:

- Remove an individual download record, with the option to delete its downloaded file.
- Clear completed records while leaving downloaded files in place.
- Reset local download statistics.
- Wipe all WebKit website data from Browser settings.
- Disable address-bar search, checksum-file discovery, automatic resume, or the optional blocker.

Downloaded files remain on your Mac unless you choose to delete them. Removing the app does not necessarily remove files outside its container or credentials stored in the macOS Keychain; Keychain items can be managed with macOS Keychain Access.

## Open source and licensing

CloakDrop is open source under the [MIT License](https://github.com/cloakyard/cloakdrop/blob/main/LICENSE). Bundled third-party components retain their own licenses. You can [inspect the source code](https://github.com/cloakyard/cloakdrop), verify the claims in this policy, and build your own copy.

## Questions and policy changes

The CloakDrop project does not hold a server-side record of your app activity for it to disclose, correct, or delete. If this policy changes, this document will show a new revision date.

For general privacy questions, [open an issue](https://github.com/cloakyard/cloakdrop/issues). For a vulnerability or concern involving private credentials or personal data, use the [private reporting instructions](https://github.com/cloakyard/cloakdrop/blob/main/SECURITY.md#reporting-a-vulnerability) instead.
