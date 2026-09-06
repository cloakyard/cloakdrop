# CloakDrop documentation

The [main README](../README.md) covers installation, current features, building and testing.
It describes the current source tree; [GitHub release notes](https://github.com/cloakyard/cloakdrop/releases)
describe each shipped build.

## Product and policies

- [Download and install](../README.md#download-and-install), including the short notarization note.
- [Current capabilities and remaining work](../apps/macos/COMPETITIVE.md).
- [Privacy policy](../PRIVACY.md), also rendered on the website.
- [Security policy and vulnerability reporting](../SECURITY.md).
- [Code of Conduct](../CODE_OF_CONDUCT.md) and [source license](../LICENSE).

## Development and distribution

- [Contributing](../CONTRIBUTING.md): setup, checks, conventions and documentation maintenance.
- [App architecture](../apps/macos/ARCHITECTURE.md): model, engine, persistence and UI contracts.
- [Native verification guide](../.agents/skills/verify/SKILL.md): builds, GUI workflows and evidence.
- [Website guide](../apps/site/README.md): Astro development, visual checks and Cloudflare settings.
- [Shared asset guide](../assets/README.md): canonical artwork and reproducible screenshots.
- [ffmpeg vendor guide](../apps/macos/Vendor/ffmpeg/README.md) and
  [yt-dlp vendor guide](../apps/macos/Vendor/yt-dlp/README.md): setup, provenance and distribution.
- [DMG installation guide](../apps/macos/scripts/dmg/ReadMe.txt).
- Agent guidance: [Codex](../AGENTS.md) and [Claude Code](../CLAUDE.md).

## September 6, 2026 audit

These reports record observed results and unresolved limits; they are dated evidence, not
a promise that every dependency, site or failure mode is covered.

- [Overview and native app verification](audits/2026-09-06-overview.md).
- [Dependencies and vendor runtime inventory](audits/2026-09-06-dependencies.md).
- [Download engine reliability](audits/2026-09-06-engine.md).
- [Video capture and extraction](audits/2026-09-06-video.md).
- [Website, animation and installation audit](audits/2026-09-06-website.md).
- [Documentation consistency audit](audits/2026-09-06-documentation.md).

Keep behavior and installation claims aligned across these living guides and the website.
Update the date and evidence when recording a new audit rather than presenting old checks as
new verification.
