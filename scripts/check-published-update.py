#!/usr/bin/env python3
"""Check that a user's production feed and its newest public archive match this checkout."""
import argparse
import json
from pathlib import Path
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-source", type=Path, default=ROOT, help="Checkout of the published native release")
    product = json.loads((parser.parse_args().native_source / "apps/macos/scripts/dmg/installer.json").read_text())
    headers = {"User-Agent": "Cloakyard-Mac-release-check/1.0"}
    feed = f"https://{product['website']}/updates/appcast.xml"
    expected = (ROOT / "apps/site/public/updates/appcast.xml").read_bytes()
    with urlopen(Request(feed, headers=headers), timeout=30) as response:
        if response.read(len(expected) + 1) != expected:
            raise ValueError(f"{feed} differs from the signed release feed")
    items = ET.fromstring(expected).findall("./channel/item")
    item = max(items, key=lambda it: tuple(map(int, it.findtext(NS + "version").split("."))))
    archive = item.find("enclosure")
    prefix = f"https://github.com/cloakyard/{product['product'].lower()}/releases/download/"
    if archive is None or not archive.get(NS + "edSignature") or not archive.get("url", "").startswith(prefix):
        raise ValueError("Missing signed GitHub release enclosure")
    with urlopen(Request(archive.attrib["url"], method="HEAD", headers=headers), timeout=60) as response:
        if response.status != 200 or response.headers.get("Content-Length") != archive.attrib["length"]:
            raise ValueError("Public update archive size differs from the signed feed")
    print(f"{product['product']} {item.findtext(NS + 'version')}: exact public feed and archive size verified")


if __name__ == "__main__":
    main()
