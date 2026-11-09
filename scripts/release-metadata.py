#!/usr/bin/env python3
"""Validate a version bump and prepare release notes without publishing anything."""
import json
import os
from pathlib import Path
import re
import subprocess


def validate(value):
    version, build = value["version"], value["build"]
    if not isinstance(version, str) or not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("version must be major.minor.patch")
    if type(build) is not int or build < 1:
        raise ValueError("build must be a positive integer")
    return tuple(map(int, version.split("."))), build


def main():
    current = json.loads(Path("version.json").read_text())
    version, build = validate(current)
    before = os.environ["BEFORE_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", before) or before == "0" * 40:
        raise ValueError("A valid previous main commit is required")
    # The first automated release migrates the version out of build.sh.
    files = subprocess.check_output(["git", "ls-tree", "--name-only", before], text=True).splitlines()
    if "version.json" in files:
        previous = json.loads(subprocess.check_output(["git", "show", f"{before}:version.json"], text=True))
    else:
        script = subprocess.check_output(["git", "show", f"{before}:scripts/build.sh"], text=True)
        previous = {
            "version": re.search(r"<key>CFBundleShortVersionString</key><string>([^<]+)</string>", script)[1],
            "build": int(re.search(r"<key>CFBundleVersion</key><string>([^<]+)</string>", script)[1]),
        }
    old_version, old_build = validate(previous)
    changed = version != old_version
    if changed and (version <= old_version or build <= old_build):
        raise ValueError("Release version and build must both increase")
    if changed:
        changelog = Path("CHANGELOG.md").read_text()
        match = re.search(r"^## " + re.escape(current["version"]) + r"(?: —[^\n]*)?\n(.*?)(?=^## |\Z)", changelog, re.M | re.S)
        if not match or not match[1].strip():
            raise ValueError("Add release notes to CHANGELOG.md for this version")
        notes = match[1].strip() + "\n\n## Install\n\nRequires Apple Silicon and macOS 13+. Download " + f"G-Clip-{current['version']}-arm64.zip" + ", unzip, quit G-Clip, and replace the app in Applications. The app is ad-hoc signed and not notarized. macOS may require Open Anyway in Privacy & Security and renewed Accessibility permission. Updates are manual.\n"
        Path("release-notes.txt").write_text(notes)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"changed={str(changed).lower()}\nversion={current['version']}\n")


if __name__ == "__main__":
    main()
