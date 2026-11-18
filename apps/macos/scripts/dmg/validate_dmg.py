#!/usr/bin/env python3
"""Verify a read-only installer and compare every app file/link with its source."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile

from ds_store import DSStore

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
CONFIG = json.loads((HERE / "installer.json").read_text())
PRODUCT = CONFIG["product"]
ICON = CONFIG["volumeIcon"]
BACKGROUND = ROOT / CONFIG["background"]


def check_app(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info["CFBundleIdentifier"] == "com.cloakyard." + PRODUCT.lower(), "Wrong app for this installer.")
    require(app.name == PRODUCT + ".app", "Pass the app with its original product name.")
    require(info["LSMinimumSystemVersion"].split(".")[0] == str(CONFIG["minimumOS"]), "Artwork OS mismatch.")
    require(run("lipo", "-archs", app / "Contents/MacOS" / info["CFBundleExecutable"]).strip() == b"arm64",
            "Artwork requires an Apple silicon build.")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", info["CFBundleShortVersionString"]), "Expected X.Y.Z.")
    build = info["CFBundleVersion"]
    require(re.fullmatch(r"[0-9]{8}(?:\.[1-9][0-9]*)?", build), "Expected YYYYMMDD or YYYYMMDD.N.")
    datetime.strptime(build.split(".")[0], "%Y%m%d")
    for extension in (app / "Contents/PlugIns").glob("*.appex"):
        ext = plistlib.loads((extension / "Contents/Info.plist").read_bytes())
        require(all(ext[k] == info[k] for k in ("CFBundleVersion", "CFBundleShortVersionString")),
                "Extension version must match its app.")
    run("codesign", "--verify", "--deep", "--strict", app)
    ents = plistlib.loads(run("codesign", "-d", "--entitlements", "-", "--xml", app))
    require(not ents.get("com.apple.security.get-task-allow"), "Package a Release build.")


def run(*args):
    result = subprocess.run([str(arg) for arg in args], capture_output=True)
    if result.returncode:
        print(result.stdout.decode(errors="replace"), file=sys.stderr)
        print(result.stderr.decode(errors="replace"), file=sys.stderr)
        result.check_returncode()
    return result.stdout


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(root):
    result = {}
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            target = os.readlink(path)
            require(not os.path.isabs(target) and path.resolve().is_relative_to(root.resolve()),
                    f"Unsafe bundle symlink: {name}")
            result[name] = ["link", target]
        elif path.is_file():
            result[name] = ["file", stat.S_IMODE(path.stat().st_mode), digest(path)]
        elif path.is_dir():
            result[name] = ["directory"]
        else:
            raise ValueError(f"Unexpected bundle entry: {name}")
    return result


def validate(dmg, source):
    run("/usr/bin/hdiutil", "verify", dmg)
    image = plistlib.loads(run("/usr/bin/hdiutil", "imageinfo", "-plist", dmg))
    require(image["Format"] == "UDZO", "Installer is not compressed read-only UDZO.")
    with tempfile.TemporaryDirectory(prefix="installer-validate-") as directory:
        mount = Path(directory) / "volume"
        mounted = False
        try:
            run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", mount, "-plist", dmg)
            mounted = True
            app = mount / f"{PRODUCT}.app"
            check_app(app)
            require(inventory(app) == inventory(source), "Packaged app differs from the verified source.")
            require((mount / "Applications").is_symlink() and os.readlink(mount / "Applications") == "/Applications",
                    "Applications link has the wrong target.")
            require((mount / "Install Guide.txt").read_bytes() == (HERE / "ReadMe.txt").read_bytes(),
                    "Install guide differs from source.")
            require(digest(mount / ".background.png") == digest(BACKGROUND),
                    "Installer background differs from the reviewed artwork.")
            require(digest(mount / ".VolumeIcon.icns") == digest(app / "Contents/Resources" / ICON),
                    "Volume icon differs from app icon.")
            visible = {p.name for p in mount.iterdir() if not p.name.startswith(".")}
            require(visible == {f"{PRODUCT}.app", "Applications", "Install Guide.txt"}, "Unexpected installer contents.")
            with DSStore.open(str(mount / ".DS_Store"), "r") as store:
                for name, position in {f"{PRODUCT}.app": (204, 282), "Applications": (556, 282),
                                       "Install Guide.txt": (380, 464)}.items():
                    require(tuple(store[name]["Iloc"]) == position, f"Wrong icon position: {name}")
                options = store["."]["icvp"]
                require(options["iconSize"] == 96 and options["textSize"] == 12,
                        "Finder icon/text dimensions changed.")
                require(options["backgroundType"] == 2 and options.get("backgroundImageAlias"),
                        "Finder background is not configured.")
                window = store["."]["bwsp"]
                require(not window["ShowToolbar"] and not window["ShowStatusBar"], "Unexpected Finder chrome.")
                require(window["WindowBounds"] == "{{240, 110}, {760, 602}}",
                        "Finder window must fit the artwork and title bar.")
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            print(f"DMG verified: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']}), "
                  f"{len(inventory(app))} matching bundle entries; layout, artwork, guide and Applications link pass.")
        finally:
            if mounted:
                run("/usr/bin/hdiutil", "detach", mount)
    print(f"SHA-256 {digest(dmg)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dmg", type=Path)
    parser.add_argument("source_app", type=Path)
    args = parser.parse_args()
    validate(args.dmg.resolve(strict=True), args.source_app.resolve(strict=True))
