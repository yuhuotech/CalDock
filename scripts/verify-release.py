#!/usr/bin/env python3
"""Verify the ZIP and DMG exactly as distributed, including stapled tickets."""
from pathlib import Path
import subprocess
import tempfile
import time

root = Path(__file__).resolve().parent.parent
name = subprocess.check_output(["python3", str(root / "scripts/release-metadata.py")], text=True).strip()
build = root / "build"


def network_check(command):
    for attempt in range(4):
        result = subprocess.run(command)
        if result.returncode == 0:
            return
        if attempt == 3:
            result.check_returncode()
        print(f"Apple verification failed; retrying ({attempt + 1}/4).", flush=True)
        time.sleep((attempt + 1) * 5)


def verify_app(app):
    subprocess.run(["python3", str(root / "scripts/verify-bundle.py"), str(app)], check=True)
    network_check(["xcrun", "stapler", "validate", str(app)])
    network_check(["spctl", "--assess", "--type", "execute", "--verbose=2", str(app)])


for extension in ("zip", "dmg"):
    subprocess.run(["shasum", "-a", "256", "-c", f"{name}.{extension}.sha256"], cwd=build, check=True)
image = build / f"{name}.dmg"
subprocess.run(["hdiutil", "verify", str(image)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(image)], check=True)
network_check(["xcrun", "stapler", "validate", str(image)])
network_check(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", str(image)])
with tempfile.TemporaryDirectory(prefix="caldock-release-check-") as temp:
    unpacked = Path(temp) / "zip"
    subprocess.run(["ditto", "-x", "-k", str(build / f"{name}.zip"), str(unpacked)], check=True)
    verify_app(unpacked / "CalDock.app")
    mount = Path(temp) / "dmg"
    mount.mkdir()
    subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(image)], check=True)
    try:
        assert (mount / "Applications").is_symlink()
        assert (mount / "Applications").readlink() == Path("/Applications")
        verify_app(mount / "CalDock.app")
        for relative in (
            "Contents/Info.plist", "Contents/MacOS/CalDock",
            "Contents/PlugIns/CalDockWidget.appex/Contents/MacOS/CalDockWidget",
        ):
            assert (mount / "CalDock.app" / relative).read_bytes() == (unpacked / "CalDock.app" / relative).read_bytes(), relative
    finally:
        subprocess.run(["hdiutil", "detach", str(mount)], check=True)
print("PASS: ZIP and DMG signatures, notarization tickets, Universal app and matching binaries")
