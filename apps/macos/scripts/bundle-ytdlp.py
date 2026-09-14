#!/usr/bin/env python3
"""Embed the frozen yt-dlp runtime without storing Mach-O code in Resources.

Apple's nonstandard-code guidance permits relative symlinks to preserve runtime paths.
PyInstaller detects Contents/MacOS and uses Contents/Frameworks as its application home,
so top-level aliases there also point to the original resource tree. No runtime is rebuilt.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys


def remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def run(*arguments):
    subprocess.run(arguments, check=True)


def is_macho(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open("rb") as handle:
        return handle.read(4) in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf")


def relocate_rpaths(path, resources):
    lines = subprocess.check_output(["otool", "-l", str(path)], text=True).splitlines()
    rpaths = {
        lines[index + 2].strip().split(" (offset ")[0][5:]
        for index, line in enumerate(lines) if line.strip() == "cmd LC_RPATH"
    }
    if not rpaths:
        return
    run("codesign", "--remove-signature", path)
    arguments = ["install_name_tool"]
    for rpath in sorted(rpaths):
        arguments += ["-delete_rpath", rpath]
    arguments += ["-add_rpath", "@loader_path/" + os.path.relpath(resources, path.parent), str(path)]
    run(*arguments)


def bundle(source, contents, entitlements):
    tree = contents / "Resources/yt-dlp"
    resources = tree / "_internal"
    frameworks = contents / "Frameworks"
    executable = contents / "MacOS/yt-dlp"
    frameworks.mkdir(parents=True, exist_ok=True)
    executable.parent.mkdir(parents=True, exist_ok=True)

    # Remove only this helper's artifacts, including leftovers from an interrupted build. The
    # resource aliases are recognizable without a manifest that could itself be half-written.
    for path in frameworks.iterdir():
        if path.name.startswith("yt-dlp-") or (
            path.is_symlink() and os.readlink(path).startswith("../Resources/yt-dlp/_internal/")
        ):
            remove(path)
    remove(tree)
    remove(executable)
    if not (source / "yt-dlp").is_file() or not (source / "_internal").is_dir():
        print("note: yt-dlp not vendored — page extraction is unavailable. Run scripts/fetch-ytdlp.sh to enable it.")
        return

    tree.mkdir(parents=True)
    run("ditto", source / "yt-dlp", executable)
    run("ditto", source / "_internal", resources)
    executable.chmod(0o755)
    (tree / "yt-dlp").symlink_to(os.path.relpath(executable, tree))

    # Preserve Python's canonical versioned framework as a unit, then flatten the remaining
    # native modules into unique names. Their import paths continue to work through symlinks.
    framework = resources / "Python.framework"
    framework_target = frameworks / "yt-dlp-Python.framework"
    shutil.move(framework, framework_target)
    framework.symlink_to(os.path.relpath(framework_target, framework.parent))
    native_files = []
    for path in sorted(resources.rglob("*")):
        if not is_macho(path):
            continue
        target = frameworks / ("yt-dlp-" + str(path.relative_to(resources)).replace("/", "--"))
        if target.exists():
            raise RuntimeError("Conflicting native runtime filename: " + target.name)
        shutil.move(path, target)
        path.symlink_to(os.path.relpath(target, path.parent))
        relocate_rpaths(target, resources)
        native_files.append(target)
    for path in resources.iterdir():
        alias = frameworks / path.name
        if alias.exists() or alias.is_symlink():
            raise RuntimeError("Conflicting PyInstaller runtime alias: " + alias.name)
        alias.symlink_to(os.path.relpath(path, frameworks))

    identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "")
    name = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY_NAME", "")
    sign = ["codesign", "--force", "--sign"]
    if not identity or identity == "-" or name in ("-", "Sign to Run Locally"):
        sign += ["-"]
    else:
        sign += [identity, "--options", "runtime", "--timestamp"]
    # Explicit leaf-first signing; --deep is for verification, never signing.
    for path in native_files:
        run(*sign, path)
    run(*sign, framework_target)
    run("codesign", "--verify", "--deep", "--strict", framework_target)
    run(*sign, "--entitlements", entitlements, executable)
    run("codesign", "--verify", "--strict", executable)
    print(f"note: bundled yt-dlp with {len(native_files)} native modules and Python.framework in Frameworks.")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: bundle-ytdlp.py <vendor directory> <app Contents directory> <helper entitlements>")
    bundle(*(Path(argument).absolute() for argument in sys.argv[1:]))
