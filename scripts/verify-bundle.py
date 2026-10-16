#!/usr/bin/env python3
"""Reject incomplete app bundles and widget binaries that bypass NSExtensionMain."""
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app = Path(sys.argv[1] if len(sys.argv) > 1 else "build/CalDock.app")
widget = app / "Contents/PlugIns/CalDockWidget.appex"
for bundle, expected in [(app, "com.yuhuo.caldock"), (widget, "com.yuhuo.caldock.widget")]:
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == expected
    binary = bundle / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    assert {"arm64", "x86_64"}.issubset(architectures), architectures
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    if bundle == app:
        assert info["SUScheduledCheckInterval"] == 3600
        assert info["SUAllowsAutomaticUpdates"] is False
        assert info["SURequireSignedFeed"] is True and info["SUVerifyUpdateBeforeExtraction"] is True
        assert info["SUFeedURL"] == "https://github.com/yuhuotech/CalDock/releases/latest/download/appcast.xml"
        assert info["SUPublicEDKey"]
        framework = app / "Contents/Frameworks/Sparkle.framework"
        assert {"arm64", "x86_64"}.issubset(subprocess.check_output(["lipo", "-archs", str(framework / "Sparkle")], text=True).split())
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    if bundle == widget:
        assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"
        assert (bundle / "Contents/Resources/holidays.json").is_file()
        for architecture in ["arm64", "x86_64"]:
            loads = subprocess.check_output(["otool", "-arch", architecture, "-l", str(binary)], text=True)
            entry = int(re.search(r"cmd LC_MAIN\s+cmdsize \d+\s+entryoff (\d+)", loads)[1])
            base = int(re.search(r"segname __TEXT\s+vmaddr (0x[0-9a-fA-F]+)", loads)[1], 16)
            symbols = subprocess.check_output(["nm", "-arch", architecture, "-gU", str(binary)], text=True)
            main = int(re.search(r"([0-9a-fA-F]+) T _main\b", symbols)[1], 16)
            imports = subprocess.check_output(["nm", "-arch", architecture, "-u", str(binary)], text=True)
            assert "_NSExtensionMain" in imports, "Widget must initialize the extension host"
            assert entry != main - base, "Widget entry points to Swift main instead of NSExtensionMain"
print("PASS: Universal app, widget extension bootstrap, resources, identifiers and signatures")
