# Signed app updates

CloakDrop embeds **Sparkle 2.10.1**, pinned in `apps/macos/project.yml`.
The host owns the updater; the headless package does not depend on Sparkle.

See the [Mac release workflow](MAC-RELEASE.md) for the Air installer and Developer ID export.

## Free Apple account / team-less builds

The default project builds Debug and Release with ad-hoc signing (`CODE_SIGN_IDENTITY=-`),
without a Team ID or provisioning profile. A paid Apple account is not needed for this route.
The local host entitlement disables library validation because ad-hoc signatures have no
Team ID with which macOS can match the embedded framework. This exception also applies to
unnotarized Release builds. Hardened runtime remains enabled for Release. The application’s
other sandbox permissions are retained.

`project-release.yml` is a separate, future Developer ID configuration with library validation
enabled. It is not required for the free-account workflow. `scripts/sign-sparkle.sh` re-signs
Sparkle’s nested helpers when an explicit certificate is used; it does not apply the host’s
entitlements to every nested binary. Developer ID signing and notarization remain unverified.

Sparkle’s Ed25519 signatures authenticate the update feed and archive, independently of Apple
signing. They do **not** notarize the app or remove Gatekeeper’s first-install trust requirements.
Existing builds without Sparkle need one manual replacement with a Sparkle-enabled build.
First install the app in a writable Applications folder, then launch it normally. Updates do
not make App Groups, Shortcuts or other provisioned capabilities available to a free account.
macOS may ask again for privacy permissions after an ad-hoc update because its code identity changes.

## User controls and network behavior

**Settings → About → Check for Updates…** starts a manual check. About also provides automatic-check and
install-on-quit preferences, both off initially. Sparkle’s standard UI handles download progress,
signature errors, installation and relaunch. Turning automatic checks off stops scheduled checks;
a manual check still works. No system profile or analytics are sent.

Feed: `https://drop.cloakyard.com/updates/appcast.xml`

Payloads: `https://github.com/cloakyard/cloakdrop/releases/download/<tag>/<archive>.zip`

The checked-in feed contains the signed release entry. Publish and verify its ZIP before deploying the matching feed. No deployment or GitHub release is performed by the build.
Cloudflare must serve XML bytes without rewriting them because the feed itself is signed.
`public/_headers` sets XML content type and a short, no-transform cache policy for this path.

## Signing key

The public key is in `project.yml` / the processed `SUPublicEDKey`.
The private key is stored only in this Mac’s login Keychain, under Sparkle’s service
`https://sparkle-project.org`, account **`com.cloakyard.cloakdrop.sparkle`**.
Each app has its own key. Never commit, print, attach or upload the private key.

After resolving the app’s packages, Sparkle tools are normally at:

```sh
apps/macos/build/Verify/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.cloakyard.cloakdrop.sparkle -p
```

Back up the private key yourself into encrypted offline storage using `generate_keys --account
com.cloakyard.cloakdrop.sparkle -x /secure/location/key-file`. On a new signing Mac import it with
`-f`. Do not replace an established key: losing it can break the update path for ad-hoc builds.
The release script checks that the built public key matches the selected Keychain account.
Keychain may ask you to allow Sparkle’s signing tools to read the key.

## Prepare a release

Choose a strictly increasing numeric build number, e.g. `20261117.1`, then `.2` for another
release that day. Marketing versions alone do not establish update ordering. All targets in
an app must retain matching build/version numbers. Start from a verified source revision.

```sh
cd apps/macos
GIT_CONFIG_COUNT=0 xcodegen generate
GIT_CONFIG_COUNT=0 xcodebuild -project CloakDrop.xcodeproj -scheme CloakDrop \
  -destination 'platform=macOS,arch=arm64' -configuration Release \
  -derivedDataPath build/Verify CURRENT_PROJECT_VERSION=20261117.1 build
cd ../..
python3 scripts/sparkle-release.py apps/macos/build/Verify/Build/Products/Release/CloakDrop.app \
  --tag vNEXT --output apps/macos/build/Updates-20261117.1
```

Optionally pass `--notes release-notes.md` (or `.txt`). `--sparkle-bin` selects another official
2.10.1 tool directory. Output is exclusive: an existing directory is never overwritten.
The script verifies the code signature, feed URL, public key, Release entitlements and increasing
build number; creates a ZIP; signs the archive and appcast; verifies both signatures; and writes
checksums. Existing published feed items are retained. Delta generation is disabled until there
is an established set of shipped builds. Appcasts infer minimum macOS and architecture from the app.

1. Upload the generated ZIP and checksum file to the specified GitHub Release.
2. Download the public ZIP and compare its SHA-256 with the prepared file.
3. Copy the generated **signed** `appcast.xml` to `apps/site/public/updates/appcast.xml`.
4. Run the website checks, review the diff, then publish through the repository’s normal workflow.
5. Check for updates in a previously installed Sparkle-enabled build and verify install/relaunch.

Publish assets **before** the feed. Do not edit signed XML after generation. Re-run the signing
tool if the feed changes. Keep old release assets available while their feed entries remain.
Publication is separate from preparation; neither script silently uploads or deploys anything.

## References

- [Sparkle setup and signing](https://sparkle-project.org/documentation/)
- [Sandbox services and code signing](https://sparkle-project.org/documentation/sandboxing/)
- [Update preferences and verification settings](https://sparkle-project.org/documentation/customization/)
- [Sparkle 2.10.1 release](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1)

## Ongoing checks

Run `python3 scripts/check-mac-dependencies.py` to compare the shipping dependencies and installer tooling with their stable upstream versions. After deploying a release, run `python3 scripts/check-published-update.py` to verify the production feed matches the signed source and the advertised archive is available at the expected size. The Mac dependencies and public updates workflow runs both checks weekly and on demand.

## Temporary website build dependency exception

Through 1 December 2026 UTC, the website audit permits only [GHSA-fc5q-39xc-vjpf](https://github.com/advisories/GHSA-fc5q-39xc-vjpf) and findings caused exclusively by that advisory. Astro uses picomatch to match build files in the trusted checkout. Cloudflare serves the resulting static assets. The exception expires at 00:00 UTC on 2 December. Unrelated high and critical advisories and audit failures still block the build. Remove the exception when patched releases resolve the advisory.

## Family update experience

The three apps use the same About section, update options and Sparkle standard user driver. The installed version and app icon identify each product. The weekly family check compares the three published tags for changes to those controls, dialog driver, framework version and updater UI preferences. Before releasing, run `python3 scripts/check-update-ux.py --checkouts /path/to/family-checkouts` from CloakDrop.

## Production verification on 18 November 2026

The installed build `20261118.1` found `20261118.2` using **Settings → About → Check for Updates** against the public HTTPS feed. **Install Update** downloaded the signed GitHub ZIP. **Install and Relaunch** replaced the app in Applications. About then displayed build `20261118.2`, and a second check reported that the app was up to date. The unauthenticated public DMG, ZIP and checksum manifest matched the local release files byte for byte.

All three apps used the same update offer, cancellable progress window, relaunch action and up-to-date dialog. An isolated copy of each release with an unavailable test feed showed Sparkle’s update error and **Cancel Update**. In those copies automatic checks and downloads started off. Enabling checks enabled the download switch, and disabling checks disabled it again. The production apps kept their own saved preferences.
