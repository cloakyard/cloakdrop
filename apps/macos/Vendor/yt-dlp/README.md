# Vendored yt-dlp

This optional helper resolves a submitted video page into metadata and selectable media URLs.
CloakDrop's own engine downloads the selected media. Without the helper, page extraction reports
that it is unavailable; ordinary downloads and browser capture of direct media remain available.

On an Apple Silicon Mac with the Xcode command-line tools installed, run from `apps/macos/`:

```bash
scripts/fetch-ytdlp.sh
```

The [fetch script](../../scripts/fetch-ytdlp.sh) is the source of truth for the version, official
release URL, and SHA-256. It currently vendors **yt-dlp 2026.08.19** from `yt-dlp_macos.zip`.
The resulting executable, `_internal/` runtime, and `build/` cache are git-ignored.

## Runtime and isolation

The official PyInstaller **onedir** archive includes an unpacked Python runtime. The script thins
native code to arm64 and normalizes Python.framework's versioned symlinks. The onedir layout lets
the helper load signed code from its fixed bundle location instead of extracting executable code
to temporary storage as the onefile distribution does.

Rebuild the app after vendoring. The [project build phase](../../project.yml) copies the runtime
beside the executable in `CloakDrop.app/Contents/Resources/yt-dlp`, signs nested code and the helper with the
appropriate app identity, and verifies signatures. The helper inherits the app's sandbox. If the
vendor inputs are absent, the build phase removes stale bundled copies.

[`YtDlpExtractor`](../../Packages/DownloaderCore/Sources/DownloadEngine/YtDlpExtractor.swift)
invokes the helper with `--ignore-config --no-plugin-dirs --no-cache-dir --simulate -J --no-playlist`,
private output files, and cancellation/timeout handling. This permits metadata requests to the submitted
page and related service endpoints, without downloading the selected media payload. Browser logins
can be supplied through a private temporary cookie jar that preserves domain/path scope. The app's
download proxy setting is not passed to the helper; see the [privacy policy](../../../../PRIVACY.md).

## Provenance and remaining runtime updates

Downloads and redirects require HTTPS. The script checks the pinned archive hash, prepares a
separate staging tree, rejects incompatible native architectures, signs the runtime, and checks
the helper's reported version before replacing the installed copy. An empty `YTDLP_SHA256` prints
the downloaded hash and stops. Run vendor scripts without a concurrent app build; replacement of
the executable and runtime is not one atomic filesystem operation.

For a version bump, verify the release's signed `SHA2-256SUMS` with the upstream release key before
updating the pin. The script checks SHA-256 but does not repeat GPG verification on each run.
Keep the complete runtime together rather than replacing individual frozen Python/native files.
Bundled dependencies retain their own licenses; preserve the upstream notices when distributing.

The [6 September 2026 dependency audit](../../../../docs/audits/2026-09-06-dependencies.md) records
archive provenance, nested-signature checks, and the full runtime inventory. The current stable
bundle still includes older Python, OpenSSL, SQLite, and Python packages; **OpenSSL 3.5.7 has a
newer security patch available**. The checked nightly/master bundles have the same runtime gap.
A proposed custom runtime rebuild is documented there and remains pending dependency approval
and end-to-end validation. A current yt-dlp release does not imply every frozen dependency is current.

The local script uses ad-hoc signing. Successful code-signature checks do not establish Developer
ID identity or Apple notarization. The current beta is locally signed and not notarized; see the
[security policy](../../../../SECURITY.md).
