#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CALDOCK_SIGN_IDENTITY:?Set CALDOCK_SIGN_IDENTITY to your Developer ID Application identity}"
: "${CALDOCK_NOTARY_PROFILE:?Set CALDOCK_NOTARY_PROFILE to an existing notarytool Keychain profile name}"
: "${CALDOCK_SPARKLE_KEY_FILE:?Set CALDOCK_SPARKLE_KEY_FILE to the private Sparkle update signing key file}"
release_name="$(python3 scripts/release-metadata.py)"
notary_credentials=(--keychain-profile "$CALDOCK_NOTARY_PROFILE")
if [[ -n "${CALDOCK_NOTARY_KEYCHAIN:-}" ]]; then
    notary_credentials+=(--keychain "$CALDOCK_NOTARY_KEYCHAIN")
fi
retry_apple_tool() {
    local attempt
    for attempt in 1 2 3 4; do
        if "$@"; then return 0; fi
        if [[ "$attempt" -lt 4 ]]; then
            printf 'Apple tool failed; retrying (%s/4).\n' "$attempt" >&2
            sleep "$((attempt * 5))"
        fi
    done
    return 1
}
bash scripts/build-app.sh release
archive="$PWD/build/$release_name.zip"
disk_image="$PWD/build/$release_name.dmg"
notarize() {
    local package="$1" report="$2" submit_status=0 submission_id
    xcrun notarytool submit "$package" "${notary_credentials[@]}" --wait --output-format json > "$report.json" || submit_status=$?
    submission_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id", ""))' "$report.json" 2>/dev/null || true)"
    if [[ -n "$submission_id" ]]; then
        xcrun notarytool log "$submission_id" "${notary_credentials[@]}" "$report-log.json" || true
    fi
    if [[ "$submit_status" -ne 0 ]]; then return "$submit_status"; fi
    python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("Notarization:",r.get("status")); assert r.get("status")=="Accepted",r' "$report.json"
}
ditto -c -k --sequesterRsrc --keepParent build/CalDock.app "$archive"
notarize "$archive" build/notarization
retry_apple_tool xcrun stapler staple build/CalDock.app
xcrun stapler validate build/CalDock.app
spctl --assess --type execute --verbose=2 build/CalDock.app
ditto -c -k --sequesterRsrc --keepParent build/CalDock.app "$archive"
python3 scripts/create-dmg.py build/CalDock.app "$disk_image"
retry_apple_tool codesign --force --sign "$CALDOCK_SIGN_IDENTITY" --timestamp "$disk_image"
notarize "$disk_image" build/notarization-dmg
retry_apple_tool xcrun stapler staple "$disk_image"
xcrun stapler validate "$disk_image"
for extension in zip dmg; do
    (cd build && shasum -a 256 "$release_name.$extension" > "$release_name.$extension.sha256")
done
python3 scripts/generate-appcast.py --key-file "$CALDOCK_SPARKLE_KEY_FILE"
printf 'Release: %s\nRelease: %s\n' "$archive" "$disk_image"
