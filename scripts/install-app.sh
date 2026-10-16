#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_source="$PWD/build/CalDock.app"
app_target="/Applications/CalDock.app"
codesign --verify --deep --strict "$app_source"
if [[ -e "$app_target" ]]; then
    existing_id="$(plutil -extract CFBundleIdentifier raw "$app_target/Contents/Info.plist")"
    [[ "$existing_id" == "com.yuhuo.caldock" ]] || { printf 'Target belongs to a different app.\n' >&2; exit 1; }
    ditto "$app_target" "$PWD/build/CalDock.previous.app"
fi
ditto "$app_source" "$app_target"
pluginkit -a "$app_target/Contents/PlugIns/CalDockWidget.appex"
codesign --verify --deep --strict "$app_target"
printf 'Installed: %s\n' "$app_target"
