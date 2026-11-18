#!/usr/bin/env python3
"""Package a notarized Developer ID app. Only --submit contacts Apple's notary service."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

DMG = Path(__file__).resolve().parents[1] / "apps/macos/scripts/dmg"


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Exported and stapled .app")
    parser.add_argument("--identity", required=True, help="Developer ID Application certificate name")
    parser.add_argument("--submit", action="store_true", help="Build, sign, submit and staple the DMG")
    parser.add_argument("--profile", help="Stored notarytool Keychain profile")
    parser.add_argument("--output", type=Path, help="New .dmg path")
    args = parser.parse_args()
    if args.submit and not (args.profile and args.output):
        parser.error("--submit needs --profile and --output")
    app = args.app.resolve(strict=True)
    product = json.loads((DMG / "installer.json").read_text())["product"]
    if app.name != product + ".app":
        parser.error(f"Expected {product}.app")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != "com.cloakyard." + product.lower():
        parser.error("App bundle identifier does not match this repository")
    run("codesign", "--verify", "--deep", "--strict", app)
    signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)], capture_output=True, text=True, check=True).stderr
    if not args.identity.startswith("Developer ID Application:") or "Authority=" + args.identity not in signature.splitlines():
        parser.error("The app must be exported with the specified Developer ID Application certificate")
    if '"' + args.identity + '"' not in run("security", "find-identity", "-v", "-p", "codesigning"):
        parser.error("Matching signing identity is unavailable in Keychain")
    run("xcrun", "stapler", "validate", app)
    run("spctl", "--assess", "--type", "execute", app)
    if not args.submit:
        print(f"Validated the exported {product} app and Developer ID identity.")
        return
    output = args.output.absolute()
    if output.suffix != ".dmg" or os.path.lexists(output):
        parser.error("Choose a new .dmg path")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as directory:
        image = Path(directory) / output.name
        run(DMG / "make-dmg.sh", app, image)
        run("codesign", "--timestamp", "--sign", args.identity, image)
        run("codesign", "--verify", "--strict", image)
        result = json.loads(run("xcrun", "notarytool", "submit", image, "--keychain-profile",
                                args.profile, "--wait", "--output-format", "json"))
        if result.get("status") != "Accepted":
            sys.exit(f"Apple returned {result.get('status')} for submission {result.get('id')}")
        run("xcrun", "stapler", "staple", image)
        run("xcrun", "stapler", "validate", image)
        run("spctl", "--assess", "--type", "open", "--context", "context:primary-signature", image)
        os.link(image, output)
    print(run("shasum", "-a", "256", output).strip())


if __name__ == "__main__":
    main()
