#!/bin/bash
# Xcode's Embed & Sign does not re-sign Sparkle's nested helpers. Archive/export
# handles this too, but explicit identity builds used by our release tools need it here.
set -euo pipefail
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "NO" ]]; then exit 0; fi
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
    # Upstream's helpers already have valid ad-hoc hardened-runtime signatures.
    exit 0
fi
framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
version="$framework/Versions/B"
if [[ ! -d "$version" ]]; then
    echo "error: Embedded Sparkle framework is missing."
    exit 1
fi
options=(--force --sign "$identity" --options runtime)
if [[ "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" == "Developer ID Application:"* ]]; then
    options+=(--timestamp)
fi
/usr/bin/codesign "${options[@]}" "$version/XPCServices/Installer.xpc"
/usr/bin/codesign "${options[@]}" --preserve-metadata=entitlements "$version/XPCServices/Downloader.xpc"
/usr/bin/codesign "${options[@]}" "$version/Autoupdate"
/usr/bin/codesign "${options[@]}" "$version/Updater.app"
/usr/bin/codesign "${options[@]}" "$framework"
/usr/bin/codesign --verify --deep --strict "$framework"
