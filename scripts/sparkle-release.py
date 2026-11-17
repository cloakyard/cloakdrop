#!/usr/bin/env python3
"""Prepare a signed Sparkle ZIP and appcast locally. Never uploads or deploys."""
import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PRODUCTS = {"cloakdrop": ("CloakDrop", "drop"), "cloaktools": ("CloakTools", "tools"), "cloakroll": ("CloakRoll", "roll")}
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def version(value):
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value), "Use a numeric, increasing CFBundleVersion.")
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def validate_feed(path, bundle_version):
    root = ET.parse(path).getroot()
    for item in root.findall("./channel/item"):
        prior = item.findtext(SPARKLE + "version")
        enclosure = item.find("enclosure")
        if prior is None and enclosure is not None:
            prior = enclosure.get(SPARKLE + "version")
        require(prior is not None, "Existing feed item has no version.")
        require(version(bundle_version) > version(prior), "Build number must exceed every published feed item.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Verified Release .app (ad-hoc is supported)")
    parser.add_argument("--tag", required=True, help="GitHub Releases tag to host the ZIP")
    parser.add_argument("--output", required=True, type=Path, help="New directory; existing output is never overwritten")
    parser.add_argument("--sparkle-bin", type=Path, help="Sparkle 2.10.1 bin directory; defaults to the resolved Xcode artifact")
    parser.add_argument("--notes", type=Path, help="Optional plain-text or Markdown release notes, embedded in the signed feed")
    args = parser.parse_args()
    # Identify the repository by its project, so renamed standalone checkouts work too.
    matches = [(name, data) for name, data in PRODUCTS.items() if (ROOT / f"apps/macos/{data[0]}.xcodeproj").exists()]
    require(len(matches) == 1, "Generate the Xcode project before preparing updates.")
    repo, (app_name, domain) = matches[0]
    account = f"com.cloakyard.{repo}.sparkle"
    identifier = f"com.cloakyard.{repo}"
    feed_url = f"https://{domain}.cloakyard.com/updates/appcast.xml"
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.tag), "Use a URL-safe release tag.")
    tools = args.sparkle_bin or ROOT / "apps/macos/build/Verify/SourcePackages/artifacts/sparkle/Sparkle/bin"
    for name in ("generate_keys", "generate_appcast", "sign_update"):
        require((tools / name).is_file(), f"Missing {name}; resolve Sparkle or pass --sparkle-bin.")
    app = args.app.resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    require(info.get("CFBundleIdentifier") == identifier, "Wrong app bundle identifier.")
    require(info.get("SUFeedURL") == feed_url, "The app is not configured for its production HTTPS feed.")
    require(info.get("SURequireSignedFeed") and info.get("SUVerifyUpdateBeforeExtraction"), "Update signature verification must stay enabled.")
    require(info.get("SUEnableSystemProfiling") is False, "System profiling must be disabled.")
    key = run(tools / "generate_keys", "--account", account, "-p")
    require(info.get("SUPublicEDKey") == key, "Built app's public key does not match the signing Keychain account.")
    run("codesign", "--verify", "--deep", "--strict", app)
    entitlements = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", str(app)]))
    require(not entitlements.get("com.apple.security.get-task-allow"), "Package a Release build, without the debugger entitlement.")
    feed = ROOT / "apps/site/public/updates/appcast.xml"
    run(tools / "sign_update", "--verify", "--account", account, feed)
    version(info["CFBundleVersion"])
    validate_feed(feed, info["CFBundleVersion"])
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    archive = output / f"{app_name}-{info['CFBundleVersion']}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
    shutil.copy2(feed, output / "appcast.xml")
    if args.notes:
        require(args.notes.suffix in {".txt", ".md"}, "Use plain-text or Markdown notes.")
        shutil.copy2(args.notes, archive.with_suffix(args.notes.suffix))
    run(tools / "generate_appcast", "--account", account, "--maximum-deltas", "0", "--maximum-versions", "0",
        "--download-url-prefix", f"https://github.com/cloakyard/{repo}/releases/download/{args.tag}/",
        "--embed-release-notes", output)
    run(tools / "sign_update", "--verify", "--account", account, output / "appcast.xml")
    tree = ET.parse(output / "appcast.xml")
    items = tree.findall("./channel/item")
    current = [item for item in items if item.findtext(SPARKLE + "version") == info["CFBundleVersion"]]
    require(len(current) == 1, "Generated feed must advertise exactly one new build.")
    enclosure = current[0].find("enclosure")
    require(enclosure is not None and enclosure.get(SPARKLE + "edSignature"), "Update archive signature is missing.")
    require(int(enclosure.get("length", "0")) == archive.stat().st_size, "Archive length mismatch.")
    run(tools / "sign_update", "--verify", "--account", account, archive, enclosure.get(SPARKLE + "edSignature"))
    (output / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in (archive, output / "appcast.xml")
    ))
    print(f"Prepared {archive}\nSigned feed: {output / 'appcast.xml'}")
    print("Publish the ZIP to the specified GitHub release first. Verify its public URL and checksum.")
    print("Then copy the signed appcast.xml to apps/site/public/updates/appcast.xml and deploy the website.")
    print("Do not edit the signed XML. Nothing was uploaded or deployed by this command.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, ET.ParseError, subprocess.CalledProcessError) as error:
        print(f"Update preparation stopped: {error}", file=sys.stderr)
        sys.exit(1)
