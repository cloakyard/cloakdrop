#!/usr/bin/env python3
"""Check the three published updaters, or pass --checkouts to compare local release candidates."""
import argparse
from pathlib import Path
import plistlib
import re
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

PRODUCTS = ("CloakDrop", "CloakRoll", "CloakTools")
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
# Other SU keys identify the individual product or configure its sandbox services.
UI_KEYS = ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates",
           "SUEnableSystemProfiling", "SUShowReleaseNotes", "SUScheduledCheckInterval",
           "SUScheduledImpatientCheckInterval")


def fetch(url):
    request = Request(url, headers={"User-Agent": "Cloakyard-Mac-release-check/1.0"})
    with urlopen(request, timeout=30) as response:
        return response.read()


def published_tag(product):
    domain = product.removeprefix("Cloak").lower()
    feed = fetch(f"https://{domain}.cloakyard.com/updates/appcast.xml")
    items = ET.fromstring(feed).findall("./channel/item")
    item = max(items, key=lambda i: tuple(map(int, i.findtext(NS + "version").split("."))))
    prefix = f"https://github.com/cloakyard/{product.lower()}/releases/download/"
    match = re.fullmatch(re.escape(prefix) + r"(v[0-9A-Za-z.\-]+)/[^/]+", item.find("enclosure").get("url"))
    if not match:
        raise ValueError(f"Unexpected release URL for {product}")
    return match.group(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkouts", type=Path, help="Parent directory of the three app repos")
    args = parser.parse_args()
    baseline = None
    for product in PRODUCTS:
        repo = product.lower()
        if args.checkouts:
            root = args.checkouts / repo
            read = lambda name: (root / name).read_bytes()
            label = "checkout"
        else:
            label = published_tag(product)
            prefix = f"https://raw.githubusercontent.com/cloakyard/{repo}/{label}/"
            read = lambda name: fetch(prefix + name)
        updater = read("apps/macos/App/App/AppUpdater.swift").decode()
        spec = read("apps/macos/project.yml").decode()
        info = plistlib.loads(read("apps/macos/App/Resources/Info.plist"))
        match = re.search(r"\n  Sparkle:\n[^\n]+\n    exactVersion: ([\d.]+)", spec)
        if not match or "SPUStandardUpdaterController(" not in updater or "userDriverDelegate: nil" not in updater:
            raise ValueError(f"{product} requires review of its Sparkle dialog driver")
        values = (updater, match.group(1), {key: info.get(key) for key in UI_KEYS})
        if baseline is not None and values != baseline:
            raise ValueError(f"{product} differs in About controls, updater driver, Sparkle version or UI settings")
        baseline = values
        print(f"{product} ({label}): Sparkle {match.group(1)}")


if __name__ == "__main__":
    main()
