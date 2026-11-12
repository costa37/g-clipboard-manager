#!/usr/bin/env python3
"""Sign the packaged app and create the release's Sparkle update feed."""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/costa37/g-clipboard-manager"
ET.register_namespace("sparkle", SPARKLE)


def create_feed(info, archive, signature, length):
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Ed25519 signature")
    version = info["CFBundleShortVersionString"]
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "G-Clip Updates"
    ET.SubElement(channel, "link").text = REPOSITORY + "/releases"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "G-Clip " + version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, "link").text = REPOSITORY + "/releases/tag/v" + version
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = info["CFBundleVersion"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "enclosure", {
        "url": f"{REPOSITORY}/releases/download/v{version}/{archive.name}",
        "length": str(length), "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": signature,
    })
    ET.indent(rss)
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True)


def main():
    output = ROOT / "dist/appcast.xml"
    output.unlink(missing_ok=True)  # Never leave an older feed after a signing failure.
    with (ROOT / "dist/G-Clip.app/Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    archive = ROOT / f"dist/G-Clip-{info['CFBundleShortVersionString']}-arm64.zip"
    signer = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    command = [str(signer), "-p"]
    secret = os.environ.get("SPARKLE_PRIVATE_KEY")
    if secret:
        command += ["--ed-key-file", "-"]
    else:
        if os.environ.get("CI"):
            raise ValueError("Configure the SPARKLE_PRIVATE_KEY repository secret before releasing")
        command += ["--account", "local.gclip.manager"]
    command.append(str(archive))
    # Do not pass secrets as command arguments or expose them to child logs.
    environment = {k: v for k, v in os.environ.items() if k != "SPARKLE_PRIVATE_KEY"}
    signature = subprocess.check_output(command, input=secret, text=True, env=environment).strip()
    environment["CLANG_MODULE_CACHE_PATH"] = str(ROOT / ".build/module-cache")
    subprocess.run(["swift", str(ROOT / "scripts/verify-update.swift"), info["SUPublicEDKey"], str(archive), signature], check=True, env=environment)
    output.write_bytes(create_feed(info, archive, signature, archive.stat().st_size))
    print(f"Created {output}")


if __name__ == "__main__":
    main()
