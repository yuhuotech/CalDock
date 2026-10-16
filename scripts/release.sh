#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CALDOCK_SIGN_IDENTITY:?Set CALDOCK_SIGN_IDENTITY to your Developer ID Application identity}"
: "${CALDOCK_NOTARY_PROFILE:?Set CALDOCK_NOTARY_PROFILE to an existing notarytool Keychain profile name}"
release_name="$(python3 scripts/release-metadata.py)"
notary_credentials=(--keychain-profile "$CALDOCK_NOTARY_PROFILE")
if [[ -n "${CALDOCK_NOTARY_KEYCHAIN:-}" ]]; then
    notary_credentials+=(--keychain "$CALDOCK_NOTARY_KEYCHAIN")
fi
bash scripts/build-app.sh release
archive="$PWD/build/$release_name.zip"
ditto -c -k --sequesterRsrc --keepParent build/CalDock.app "$archive"
submit_status=0
xcrun notarytool submit "$archive" "${notary_credentials[@]}" --wait --output-format json > build/notarization.json || submit_status=$?
submission_id="$(python3 -c 'import json; print(json.load(open("build/notarization.json")).get("id", ""))' 2>/dev/null || true)"
if [[ -n "$submission_id" ]]; then
    xcrun notarytool log "$submission_id" "${notary_credentials[@]}" build/notarization-log.json || true
fi
if [[ "$submit_status" -ne 0 ]]; then exit "$submit_status"; fi
python3 -c 'import json; r=json.load(open("build/notarization.json")); print("Notarization:",r.get("status")); assert r.get("status")=="Accepted",r'
xcrun stapler staple build/CalDock.app
xcrun stapler validate build/CalDock.app
spctl --assess --type execute --verbose=2 build/CalDock.app
ditto -c -k --sequesterRsrc --keepParent build/CalDock.app "$archive"
(cd build && shasum -a 256 "$release_name.zip" > "$release_name.zip.sha256")
printf 'Release: %s\n' "$archive"
