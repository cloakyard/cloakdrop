# Mac release workflow

## Versions and source layout

`apps/macos/project.yml` owns `MARKETING_VERSION` (X.Y.Z) and `CURRENT_PROJECT_VERSION` (YYYYMMDD.N). Use the release date in India and start N at 1. Increment N for another build on the same date. Both values expand into the built Info.plist. Embedded app extensions inherit them. Each product advances independently. Existing date-only builds compare as revision zero. Sparkle checks the proposed build against all previously published feed entries.

For a stable release use the tag `vX.Y.Z`. For a beta use `vX.Y.Z-beta.YYYYMMDD.N`. Keep historical release tags and update feeds intact. Choose a new marketing version for a new stable tag.

Native entry points, state and updater coordination live in `apps/macos/App/App/`. Feature UI and operations live in `App/Features/`, shared presentation helpers in `App/Shared/` and app resources in `App/Resources/`. The headless package and its tests live under `apps/macos/Packages/`. Each product keeps its own feature modules and extension targets.

## Build the local installer

From the repo root, using Xcode, XcodeGen and Python 3.11 or later:

```sh
cd apps/macos
GIT_CONFIG_COUNT=0 xcodegen generate
GIT_CONFIG_COUNT=0 xcodebuild -scheme CloakDrop -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Verify build
python3.13 -m venv build/dmg-tools
build/dmg-tools/bin/python -m pip install --require-hashes --only-binary=:all: -r scripts/dmg/requirements.txt
scripts/dmg/make-dmg.sh build/Verify/Build/Products/Release/CloakDrop.app build/CloakDrop.dmg
```

The packager mounts its read-only output and verifies the signed app against its source, the Applications link, the guide, the artwork and the Finder window layout. Choose a new output filename each time. `DMG_PYTHON` can point to an existing environment with the pinned packaging tools.

The masthead uses an exact copy of [Cloakyard’s family mark](https://github.com/cloakyard/cloakyard/blob/7f3f9b987a619b7c8f929c9e5f7cea7bc9312b40/public/cloakyard-mark.svg). The draggable bundle and volume icon use the product icon. The Swift renderer in `scripts/dmg/` (relative to `apps/macos`) reads its own local mark and installer configuration. To refresh the artwork, run `swift scripts/dmg/background.swift <output.png>` and `sips -s dpiWidth 144 -s dpiHeight 144 <output.png>` on the background path listed in `installer.json` (relative to the repository root).

## Developer ID after enrollment

1. Add your paid team to Xcode, create its Developer ID Application certificate and keep the private key in Keychain. Register the host and Share Extension IDs and their shared group `group.com.cloakyard.cloakdrop`. Verify Share → CloakDrop with the provisioned build. Include the optional ffmpeg and yt-dlp helpers used in the intended distribution and verify their signatures in the exported app.
2. Run `GIT_CONFIG_COUNT=0 xcodegen generate --spec project-release.yml` in `apps/macos`. Select your paid team and the matching signing/provisioning settings for the app and its extension targets in Xcode. Archive the Release scheme for My Mac. Use Organizer → Distribute App → Direct Distribution, complete Apple notarization, and export the stapled app. Verify the exported build and capabilities on a separate Mac. Use the regular project spec when returning to local ad-hoc development.
3. Store notary credentials using `xcrun notarytool store-credentials`. Supply the profile name and the certificate’s full name to the following commands from the repo root. The first checks the stapled app and identity locally. The second submits the signed installer to Apple, waits for acceptance, staples the ticket and checks Gatekeeper.

```sh
python3 scripts/developer-id-dmg.py "/path/to/CloakDrop.app" --identity "$DEVELOPER_ID"
python3 scripts/developer-id-dmg.py "/path/to/CloakDrop.app" --identity "$DEVELOPER_ID" \
  --submit --profile "$NOTARY_PROFILE" --output "/path/to/CloakDrop-signed.dmg"
```

4. Run [Sparkle packaging](UPDATES.md) on the same exported, stapled app. Keep the existing app-specific Ed25519 key. Verify a signed update from the previous ad-hoc install and test first launch on a clean Mac before publishing the installer, ZIP and signed feed.

Apple documents the [notarization and stapling sequence](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Local verification on 18 November 2026

The arm64 Release build `20261118.1` passed strict code signature verification. The mounted read-only DMG and the installed CloakDrop app matched across all 456 bundle entries. In Finder, the Cloakyard family mark appeared in the header, the product icon and Applications shortcut occupied the two drag positions, and the Install Guide used the shared lower slot. The source SVG matched the pinned Cloakyard original byte for byte.

Sparkle generated and verified a local signed appcast and ZIP for this installed build using its existing product key. The public feed and GitHub release were unchanged during verification.

The Developer ID project spec parsed locally, and the distribution preflight rejected the ad-hoc app. Apple submission, the provisioned feature checks and the clean-Mac Gatekeeper test require the enrolled team.
