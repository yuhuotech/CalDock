#!/usr/bin/env python3
"""Create a compressed disk image with a drag-to-Applications shortcut."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
image = Path(sys.argv[2]).resolve()
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
image.parent.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix="dmg-staging-", dir=image.parent) as temp:
    staging = Path(temp)
    subprocess.run(["ditto", str(app), str(staging / "CalDock.app")], check=True)
    (staging / "Applications").symlink_to("/Applications")
    subprocess.run([
        "hdiutil", "create", "-ov", "-format", "UDZO", "-fs", "HFS+",
        "-volname", f"CalDock {info['CFBundleShortVersionString']}",
        "-srcfolder", str(staging), str(image),
    ], check=True)
