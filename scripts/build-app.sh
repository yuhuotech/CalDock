#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    printf 'Usage: bash scripts/build-app.sh [release|debug]\n' >&2
    exit 1
fi
swift build -c "$configuration" --arch arm64 --arch x86_64
bin_dir="$(swift build -c "$configuration" --arch arm64 --arch x86_64 --show-bin-path)"
app_dir="$PWD/build/CalDock.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CalDock" "$app_dir/Contents/MacOS/CalDock"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
swift scripts/generate-icon.swift build/CalDock.iconset
iconutil -c icns build/CalDock.iconset -o "$app_dir/Contents/Resources/CalDock.icns"
for bundle in "$bin_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$app_dir/Contents/Resources/"
done
framework_dir="$app_dir/Contents/Frameworks/Sparkle.framework"
mkdir -p "$app_dir/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$framework_dir"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"
widget_dir="$app_dir/Contents/PlugIns/CalDockWidget.appex"
mkdir -p "$widget_dir/Contents/MacOS" "$widget_dir/Contents/Resources"
cp Resources/Widget-Info.plist "$widget_dir/Contents/Info.plist"
cp Sources/CalendarCore/Resources/holidays.json "$widget_dir/Contents/Resources/"
widget_arches=(arm64 x86_64)
for widget_arch in "${widget_arches[@]}"; do
    core_dir="$PWD/build/widget-$widget_arch"
    mkdir -p "$core_dir"
    xcrun swiftc -parse-as-library -emit-module -emit-library -static -module-name CalendarCore \
        -target "$widget_arch-apple-macos14.0" -O Sources/CalendarCore/*.swift \
        -emit-module-path "$core_dir/CalendarCore.swiftmodule" -o "$core_dir/libCalendarCore.a"
    xcrun swiftc -parse-as-library -application-extension -module-name CalDockWidget \
        -target "$widget_arch-apple-macos14.0" -O -I "$core_dir" -L "$core_dir" -lCalendarCore \
        -Xlinker -e -Xlinker _NSExtensionMain -Xlinker -application_extension \
        Widget/CalDockWidget.swift -o "$core_dir/CalDockWidget"
done
lipo -create build/widget-arm64/CalDockWidget build/widget-x86_64/CalDockWidget -output "$widget_dir/Contents/MacOS/CalDockWidget"
sign_identity="${CALDOCK_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" ]]; then
    sign_identity="$(security find-identity -v -p codesigning | awk '/Developer ID Application:.*\(3BH46GJY6D\)/ {print $2; exit}')"
fi
if [[ -z "$sign_identity" ]]; then
    printf 'No matching Developer ID found. Set CALDOCK_SIGN_IDENTITY explicitly (use - only for isolated local development).\n' >&2
    exit 1
fi
sign_bundle() {
    local attempt
    local sign_args=(--force --sign "$sign_identity")
    if [[ "$sign_identity" != "-" ]]; then sign_args+=(--options runtime --timestamp); fi
    for attempt in 1 2 3; do
        if codesign "${sign_args[@]}" "$@"; then return 0; fi
        if [[ "$attempt" -lt 3 ]]; then
            printf 'Signing failed; retrying with timestamp requirements unchanged (%s/3).\n' "$attempt" >&2
            sleep "$((attempt * 3))"
        fi
    done
    return 1
}
sign_bundle --entitlements Resources/Widget.entitlements "$widget_dir"
for component in "$framework_dir/Versions/B/Autoupdate" \
    "$framework_dir/Versions/B/Updater.app" \
    "$framework_dir/Versions/B/XPCServices/Downloader.xpc" \
    "$framework_dir/Versions/B/XPCServices/Installer.xpc"; do
    sign_bundle --preserve-metadata=identifier,entitlements "$component"
done
sign_bundle "$framework_dir"
sign_bundle --entitlements Resources/CalDock.entitlements "$app_dir"
touch "$app_dir"
python3 scripts/verify-bundle.py "$app_dir"
printf '\nBuilt: %s\nOpen: open "%s"\n' "$app_dir" "$app_dir"
