# Vendored yt-dlp

This optional helper resolves submitted video pages and playlists into metadata and selectable media URLs.
CloakDrop's own engine downloads the selected media. Without the helper, page extraction reports
that it is unavailable; ordinary downloads and browser capture of direct media remain available.

On an Apple Silicon Mac with the Xcode command-line tools installed, run from `apps/macos/`:

```bash
scripts/fetch-ytdlp.sh
```

The [fetch script](../../scripts/fetch-ytdlp.sh) is the source of truth for the version, official
release URL, and SHA-256. It currently vendors **yt-dlp 2026.10.26** from `yt-dlp_macos.zip`.
The resulting executable, `_internal/` runtime, and `build/` cache are git-ignored.

## Runtime and isolation

The official PyInstaller **onedir** archive includes an unpacked Python runtime. The script thins
native code to arm64 and normalizes Python.framework's versioned symlinks. The onedir layout lets
the helper load signed code from its fixed bundle location instead of extracting executable code
to temporary storage as the onefile distribution does.

Rebuild the app after vendoring. The [project build phase](../../project.yml) invokes
[`bundle-ytdlp.py`](../../scripts/bundle-ytdlp.py) using Xcode's Python 3. It places the executable in
`Contents/MacOS`, the Python framework and native modules in `Contents/Frameworks`, and the remaining
frozen runtime resources in `Contents/Resources/yt-dlp`. Relative symlinks preserve the original
import paths and PyInstaller's app-bundle runtime lookup. Existing library search paths are adjusted
to this layout; the official runtime is preserved without rebuilding or replacing dependencies.
This follows [Apple's guidance for nonstandard code structures](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle).

The build signs native components individually, then the framework and sandbox-inheriting helper,
and verifies signatures. `--deep` is used only for verification. The helper keeps its current library
validation exception until removal can be verified with Developer ID signing. If vendor inputs are
absent, the build removes both the resource tree and its relocated code and symlinks.

[`YtDlpExtractor`](../../Packages/DownloaderCore/Sources/DownloadEngine/YtDlpExtractor.swift)
invokes the helper with `--ignore-config --no-plugin-dirs --no-cache-dir --simulate -J`,
private output files, and cancellation/timeout handling. Individual pages use `--no-playlist`.
The playlist preview instead uses `--flat-playlist --yes-playlist --playlist-end 101`, displays
at most 100 entries, and resolves only selected pages when their queued transfers start.
This permits metadata requests to the submitted page and related service endpoints, without
downloading the selected media payload. Playlist import currently accepts public pages without
exporting browser cookies. For individual browser-page resolution, browser logins
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
archive provenance, nested-signature checks, and the older runtime inventory. The
[October 29 update](../../../../docs/audits/2026-10-29-youtube.md) verifies the new signed stable
archive and a sandboxed download of the reported YouTube video. It updates Python to 3.14.7,
brotli to 1.2.1, certifi to 2026.10.23 and curl_cffi to 0.17.0, among other bundled packages.
It still freezes **OpenSSL 3.5.7 and SQLite 3.50.4**, and Python 3.14.7 is behind current 3.14
patches. A current yt-dlp release does not imply every frozen dependency is current.
A custom runtime rebuild was previously considered and declined in favour of the official bundle.
The [12 September recheck](../../../../docs/audits/2026-09-12-progress-and-dependencies.md#remaining-runtime-update--requires-new-build-dependencies)
confirms that this gap remains and records current custom-build targets.
On [October 7](../../../../docs/audits/2026-10-07-dependencies.md), the maintainer
explicitly chose to keep the official stable bundle and retain this exception
instead of introducing a custom runtime build. This decision was reconfirmed for
1.0.0-rc.1 on [October 19](../../../../docs/audits/2026-10-19-dependencies.md).
The exception remains explicit; it is not a claim that the frozen runtime is current.

The [November 3 full audit](../../../../docs/audits/2026-11-03-full-audit.md#dependency-currency)
rechecks the official 2026.10.26 bundle and six live media cases. Python 3.14.7, OpenSSL 3.5.7,
SQLite 3.50.4 and websockets 17.3 remain behind upstream releases. The other reported Python
packages match current PyPI versions. The existing choice to preserve the complete official
bundle remains in effect; no individual frozen dependency was replaced.

The [November 17 control/dependency audit](../../../../docs/audits/2026-11-17-dependencies-and-controls.md)
confirms that 2026.10.26 remains the latest official stable bundle. Python, OpenSSL, SQLite and
websockets still lag upstream; pycryptodomex 3.24.1 now also trails 3.24.2. The complete official
runtime remains intact under the existing exception.

The local script uses ad-hoc signing. Successful code-signature checks do not establish Developer
ID identity or Apple notarization. Locally signed builds are not notarized; see the
[security policy](../../../../SECURITY.md).
