#!/bin/sh
# Render the layered product icon once per appearance at 1024px, then prefilter
# to the sidebar's exact 44pt footprint at each macOS backing scale.
set -eu
document=${1:?Pass an Icon Composer document}
assets="$(dirname "$0")/../App/Resources/Assets.xcassets/SidebarAppIcon.imageset"
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
staging=$(mktemp -d)
trap 'rm -r "$staging"' EXIT
for appearance in Default Dark; do
    "$ictool" "$document" --export-image --output-file "$staging/master.png" \
        --platform macOS --rendition "$appearance" --width 1024 --height 1024 --scale 1 --design-generation 27
    for scale in 1 2; do
        pixels=$((44 * scale))
        /usr/bin/sips --resampleHeightWidth "$pixels" "$pixels" "$staging/master.png" \
            --out "$staging/$appearance@${scale}x.png" >/dev/null
    done
done
for appearance in Default Dark; do
    for scale in 1 2; do
        mv "$staging/$appearance@${scale}x.png" "$assets/"
    done
done
