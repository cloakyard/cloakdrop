#!/usr/bin/env python3
"""Build an exclusively published, verified Air DMG. Does not sign or notarize."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

import dmgbuild

from validate_dmg import PRODUCT, BACKGROUND, ICON, check_app, validate

HERE = Path(__file__).resolve().parent


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    # Do not resolve the final component: even a broken output symlink is a collision.
    output = args.output.absolute()
    if output.suffix != ".dmg" or os.path.lexists(output):
        parser.error("Choose a new .dmg path; existing artifacts are never overwritten.")
    check_app(app)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".installer-", dir=output.parent) as temporary:
        work = Path(temporary)
        staged = work / f"{PRODUCT}.app"
        run("/usr/bin/ditto", app, staged)
        guide = work / "Install Guide.txt"
        guide.write_bytes((HERE / "ReadMe.txt").read_bytes())
        run("/usr/bin/swift", HERE / "guide-icon.swift", guide)
        candidate = work / "candidate.dmg"
        dmgbuild.build_dmg(str(candidate), PRODUCT, settings={
            "format": "UDZO", "filesystem": "HFS+", "compression_level": 9,
            "files": [str(staged), str(guide)], "symlinks": {"Applications": "/Applications"},
            "icon": str(staged / "Contents/Resources" / ICON),
            "background": str(BACKGROUND),
            # Finder's frame includes its 32pt title bar; preserve all 570pt of artwork.
            "window_rect": ((240, 110), (760, 602)),
            "icon_locations": {f"{PRODUCT}.app": (204, 282), "Applications": (556, 282),
                               "Install Guide.txt": (380, 464)},
            "icon_size": 96, "text_size": 12, "arrange_by": None,
            "show_icon_preview": False, "show_toolbar": False, "show_status_bar": False,
            # Leave app extensions to Finder's preference. Setting this flag adds forbidden
            # FinderInfo to the signed bundle. Only the unsigned guide receives metadata.
            "show_sidebar": False, "hide_extensions": ["Install Guide.txt"],
            "default_view": "icon-view", "include_icon_view_settings": True,
            "include_list_view_settings": False,
        }, lookForHiDPI=False)
        validate(candidate, app)
        # Same-filesystem link is atomic and fails if another invocation published this path.
        os.link(candidate, output)
    print(f"Created {output}.")


if __name__ == "__main__":
    main()
