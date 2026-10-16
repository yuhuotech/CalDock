#!/usr/bin/env python3
"""Validate release versions and provide a consistent distribution filename."""
import argparse
import os
from pathlib import Path
import plistlib
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--github-output", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
app = plistlib.loads((root / "Resources/Info.plist").read_bytes())
widget = plistlib.loads((root / "Resources/Widget-Info.plist").read_bytes())
version = app["CFBundleShortVersionString"]
if not re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", version):
    parser.error("App version must have the form MAJOR.MINOR.PATCH")
for key in ("CFBundleShortVersionString", "CFBundleVersion"):
    if app[key] != widget[key]:
        parser.error(f"App and widget {key} must match")
if os.environ.get("GITHUB_ACTIONS") == "true":
    if os.environ.get("GITHUB_REF_TYPE") != "tag":
        parser.error("GitHub packaging requires a version tag")
    tag_pattern = re.escape(f"v{version}") + r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    if not re.fullmatch(tag_pattern, os.environ.get("GITHUB_REF_NAME", "")):
        parser.error(f"Tag must be v{version} (optionally with +build metadata) to match the app version")
name = f"CalDock-universal-{version}"
if args.github_output:
    with args.github_output.open("a") as output:
        output.write(f"version={version}\nname={name}\n")
print(name)
