#!/usr/bin/env python3
"""Compare the app's native and installer dependency pins with stable upstream releases."""
import json
from pathlib import Path
import re
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "apps/macos"


def fetch(url):
    request = Request(url, headers={"User-Agent": "Cloakyard-Mac-release-check"})
    with urlopen(request, timeout=30) as response:
        return response.read()


def github(repo):
    return json.loads(fetch(f"https://api.github.com/repos/{repo}/releases/latest"))["tag_name"].lstrip("v")


def pinned(path, pattern):
    match = re.search(pattern, path.read_text(), re.MULTILINE)
    if not match:
        raise ValueError(f"Could not read dependency pin in {path.relative_to(ROOT)}")
    return match.group(1)


def main():
    pins = [("Sparkle", pinned(MAC / "project.yml", r'(?s)\n  Sparkle:\n[^\n]+\n    exactVersion: ([\d.]+)'),
             github("sparkle-project/Sparkle"))]
    for lock in sorted((MAC / "Packages").glob("*/Package.resolved")):
        for package in json.loads(lock.read_text())["pins"]:
            if package["identity"] == "grdb.swift":
                pins.append(("GRDB", package["state"]["version"], github("groue/GRDB.swift")))
    vendor = MAC / "Vendor"
    if (vendor / "yt-dlp").is_dir():
        pins.append(("yt-dlp official bundle", pinned(MAC / "scripts/fetch-ytdlp.sh", r'^YTDLP_VERSION="([^"]+)"'),
                     github("yt-dlp/yt-dlp")))
    if (vendor / "ffmpeg").is_dir():
        versions = re.findall(r'href="ffmpeg-(\d+\.\d+(?:\.\d+)?)\.tar\.xz"', fetch("https://ffmpeg.org/releases/").decode())
        latest = max(versions, key=lambda value: tuple(map(int, value.split("."))))
        pins.append(("FFmpeg", pinned(MAC / "scripts/fetch-ffmpeg.sh", r'^FFMPEG_VERSION="([^"]+)"'), latest))
    requirements = MAC / "scripts/dmg/requirements.txt"
    for line in requirements.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        name, version = line.split()[0].split("==")
        upstream = json.loads(fetch(f"https://pypi.org/pypi/{name}/json"))["info"]["version"]
        pins.append((name, version, upstream))
    for name, current, latest in pins:
        print(f"{name}: {current} (stable upstream {latest})")
    return int(any(current != latest for _, current, latest in pins))


if __name__ == "__main__":
    raise SystemExit(main())
