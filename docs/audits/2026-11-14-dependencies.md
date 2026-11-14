# Native dependency recheck — 14 November 2026

The native development branch already uses the current stable direct dependencies: GRDB 7.12.0, FFmpeg 9.0.2 and the official yt-dlp 2026.10.26 onedir bundle. Checked against the upstream release pages; no native library or UI change is needed. The website dependencies are audited separately from its published main branch.

Fresh validation passes all 673 core tests, strict SwiftLint and localization validation. The installed vendor FFmpeg reports 9.0.2 and retains its local-file-only, network-disabled configuration. The official yt-dlp helper launches. No installer, native version or release is changed.

The maintainer-approved official-bundle exception remains: yt-dlp freezes its Python/OpenSSL/SQLite and Python package versions. A current yt-dlp release does not mean those embedded libraries are current. Keep the verified complete upstream archive, checksum and existing licensing/signing safeguards; do not replace individual frozen files or introduce a custom runtime. See [vendor policy](../../apps/macos/Vendor/yt-dlp/README.md) and the [November 3 runtime inventory](2026-11-03-full-audit.md#dependency-currency).

Sources: [GRDB](https://github.com/groue/GRDB.swift/releases/tag/v7.12.0), [FFmpeg](https://ffmpeg.org/download.html), [yt-dlp](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26). Fresh receipts: `dependencies-2026-11-14/manifest.json`. This is software/dependency evidence, not new live-service, physical interruption, distribution or native visual acceptance.
