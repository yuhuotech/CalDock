#!/usr/bin/env python3
"""Generate a signed Sparkle feed for the exact notarized ZIP being published."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from urllib.parse import quote

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--key-file", required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
info = plistlib.loads((root / "Resources/Info.plist").read_bytes())
name = subprocess.check_output(["python3", str(root / "scripts/release-metadata.py")], text=True).strip()
archive = root / "build" / f"{name}.zip"
version = info["CFBundleShortVersionString"]
tag = os.environ.get("GITHUB_REF_NAME") if os.environ.get("GITHUB_REF_TYPE") == "tag" else f"v{version}"
prefix = f"https://github.com/yuhuotech/CalDock/releases/download/{quote(tag, safe='')}/"
with tempfile.TemporaryDirectory(prefix="appcast-", dir=root / "build") as temp:
    staging = Path(temp)
    shutil.copy2(archive, staging / archive.name)
    subprocess.run([
        str(root / ".build/artifacts/sparkle/Sparkle/bin/generate_appcast"),
        "--ed-key-file", str(args.key_file.resolve()), "--maximum-deltas", "0",
        "--download-url-prefix", prefix,
        "--link", "https://github.com/yuhuotech/CalDock",
        "--full-release-notes-url", f"https://github.com/yuhuotech/CalDock/releases/tag/{quote(tag, safe='')}",
        str(staging),
    ], check=True)
    feed = staging / "appcast.xml"
    item = ET.parse(feed).find("channel/item")
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    assert item is not None
    assert item.findtext(f"{namespace}version") == info["CFBundleVersion"]
    assert item.findtext(f"{namespace}shortVersionString") == version
    enclosure = item.find("enclosure")
    assert enclosure is not None and enclosure.get("url") == prefix + archive.name
    assert enclosure.get(f"{namespace}edSignature")
    assert int(enclosure.get("length")) == archive.stat().st_size
    verifier = root / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
    subprocess.run([str(verifier), "--verify", "--ed-key-file", str(args.key_file.resolve()), str(feed)], check=True)
    subprocess.run([str(verifier), "--verify", "--ed-key-file", str(args.key_file.resolve()), str(archive), enclosure.get(f"{namespace}edSignature")], check=True)
    shutil.copy2(feed, root / "build/appcast.xml")
print("PASS: signed appcast matches the published version, ZIP URL and size")
