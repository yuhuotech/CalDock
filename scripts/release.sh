#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CALDOCK_SIGN_IDENTITY:?Set CALDOCK_SIGN_IDENTITY to your Developer ID Application identity}"
: "${CALDOCK_NOTARY_PROFILE:?Set CALDOCK_NOTARY_PROFILE to an existing notarytool Keychain profile name}"
bash scripts/build-app.sh release
archive="$PWD/build/CalDock-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent build/CalDock.app "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$CALDOCK_NOTARY_PROFILE" --wait --output-format json > build/notarization.json
python3 -c 'import json; r=json.load(open("build/notarization.json")); print("Notarization:",r.get("status")); assert r.get("status")=="Accepted",r'
xcrun stapler staple build/CalDock.app
xcrun stapler validate build/CalDock.app
spctl --assess --type execute --verbose=2 build/CalDock.app
ditto -c -k --sequesterRsrc --keepParent build/CalDock.app "$archive"
shasum -a 256 "$archive" > build/CalDock-macos-universal.zip.sha256
printf 'Release: %s\n' "$archive"
