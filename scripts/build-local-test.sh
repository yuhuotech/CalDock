#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="debug"
swift build -c "$configuration" --arch arm64 --arch x86_64 -Xswiftc -D -Xswiftc CALDOCK_DEV_BUILD
bin_dir="$(swift build -c "$configuration" --arch arm64 --arch x86_64 --show-bin-path)"
app_dir="$PWD/build/CalDock-local.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Frameworks"
cp "$bin_dir/CalDock" "$app_dir/Contents/MacOS/CalDock"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
cp LICENSE "$app_dir/Contents/Resources/CalDock-LICENSE.txt"
cp Sources/CalendarCore/Resources/holidays.json "$app_dir/Contents/Resources/"
cp Sources/CalendarCore/Resources/HolidayData-LICENSE.txt "$app_dir/Contents/Resources/"
swift scripts/generate-icon.swift build/CalDock-local.iconset
iconutil -c icns build/CalDock-local.iconset -o "$app_dir/Contents/Resources/CalDock.icns"
for bundle in "$bin_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$app_dir/Contents/Resources/"
done
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$app_dir/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app_dir/Contents/Resources/Sparkle-LICENSE.txt"

plutil -replace CFBundleName -string "CalDock 本地测试" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string "CalDock 本地测试" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "com.yuhuo.caldock.local" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleURLTypes.0.CFBundleURLName -string "com.yuhuo.caldock.local" "$app_dir/Contents/Info.plist"
plutil -replace CFBundleURLTypes.0.CFBundleURLSchemes.0 -string "caldock-local" "$app_dir/Contents/Info.plist"
plutil -replace SUEnableAutomaticChecks -bool false "$app_dir/Contents/Info.plist"

codesign --force --sign - "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
for component in "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    "$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"; do
    codesign --force --sign - "$component"
done
codesign --force --sign - "$app_dir/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf 'Built local test app: %s\n' "$app_dir"
