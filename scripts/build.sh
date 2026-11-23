#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
identity="${BREEZE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning | awk '/Apple Development:/{print $2; exit}')
fi
if [[ -z "$identity" || "$identity" == "-" ]]; then
    print -u2 "A stable Apple signing identity is required for one-time helper approval. Set BREEZE_SIGNING_IDENTITY to an Apple Development or Developer ID Application identity."
    exit 1
fi
swift build -c release
app="${BREEZE_APP_PATH:-${PWD}/dist/Breeze.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
# Replace executable inodes rather than overwriting pages mapped by a running
# copy. In-place writes can make macOS kill that copy for an invalid signature.
cp .build/release/Breeze "$app/Contents/MacOS/.Breeze.new"
mv -f "$app/Contents/MacOS/.Breeze.new" "$app/Contents/MacOS/Breeze"
cp .build/release/BreezeHelper "$app/Contents/MacOS/.BreezeHelper.new"
mv -f "$app/Contents/MacOS/.BreezeHelper.new" "$app/Contents/MacOS/BreezeHelper"
cp .build/release/BreezeMCP "$app/Contents/MacOS/.BreezeMCP.new"
mv -f "$app/Contents/MacOS/.BreezeMCP.new" "$app/Contents/MacOS/BreezeMCP"
cp scripts/local.breeze.fancontrol.helper.plist "$app/Contents/Library/LaunchDaemons/"
widget="$app/Contents/PlugIns/BreezeWidgets.appex"
mkdir -p "$widget/Contents/MacOS"
cp .build/release/BreezeWidgets "$widget/Contents/MacOS/.BreezeWidgets.new"
mv -f "$widget/Contents/MacOS/.BreezeWidgets.new" "$widget/Contents/MacOS/BreezeWidgets"
cat > "$widget/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BreezeWidgets</string>
<key>CFBundleIdentifier</key><string>local.breeze.fancontrol.widgets</string>
<key>CFBundleName</key><string>Breeze Widgets</string>
<key>CFBundleDisplayName</key><string>Breeze</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSExtension</key><dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict></plist>
PLIST
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Breeze</string>
<key>CFBundleIdentifier</key><string>local.breeze.fancontrol</string>
<key>CFBundleName</key><string>Breeze</string>
<key>CFBundleDisplayName</key><string>Breeze</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.5.0</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Breeze</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSLocalNetworkUsageDescription</key><string>Breeze discovers devices on your local network and reads their advertised names and services when you choose Scan devices.</string>
<key>NSLocationUsageDescription</key><string>Breeze uses Location Services only to read the name of your connected Wi-Fi network when you choose Allow Wi-Fi name.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>Breeze uses Location Services only to read the name of your connected Wi-Fi network when you choose Allow Wi-Fi name.</string>
<key>NSBonjourServices</key><array>
<string>_workstation._tcp</string><string>_smb._tcp</string><string>_ssh._tcp</string>
<string>_airplay._tcp</string><string>_raop._tcp</string><string>_googlecast._tcp</string>
<string>_ipp._tcp</string><string>_ipps._tcp</string><string>_http._tcp</string><string>_hap._tcp</string>
<string>_companion-link._tcp</string><string>_apple-mobdev2._tcp</string>
<string>_rdlink._tcp</string><string>_device-info._tcp</string><string>_remotepairing._tcp</string>
</array>
<key>NSDesktopFolderUsageDescription</key><string>Breeze scans folders you choose to map file sizes and find duplicate contents.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Breeze scans folders you choose to map file sizes and find duplicate contents.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Breeze scans folders you choose to map file sizes and find duplicate contents.</string>
</dict></plist>
PLIST
swift scripts/icon.swift "$app/Contents/Resources/Breeze.icns"
plutil -lint "$app/Contents/Library/LaunchDaemons/local.breeze.fancontrol.helper.plist"
codesign --force --options runtime --sign "$identity" --identifier local.breeze.fancontrol.helper "$app/Contents/MacOS/BreezeHelper"
codesign --force --options runtime --sign "$identity" --identifier local.breeze.fancontrol.mcp "$app/Contents/MacOS/BreezeMCP"
# The app and its sandboxed widget share a team-prefixed app group, which macOS
# allows without a provisioning profile. Both read the group from BreezeAppGroup.
team=$(codesign -dv --verbose=2 "$app/Contents/MacOS/BreezeHelper" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2}')
if [[ -z "$team" || "$team" == "not set" ]]; then
    print -u2 "The signing identity has no team identifier; cannot sign the widget extension."
    exit 1
fi
group="$team.local.breeze.fancontrol"
entitlements="$(mktemp -d)"
trap 'rm -rf "$entitlements"' EXIT
cat > "$entitlements/app.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array><string>$group</string></array>
</dict></plist>
PLIST
cat > "$entitlements/widget.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.application-groups</key><array><string>$group</string></array>
</dict></plist>
PLIST
plutil -replace BreezeAppGroup -string "$group" "$app/Contents/Info.plist"
plutil -replace BreezeAppGroup -string "$group" "$widget/Contents/Info.plist"
codesign --force --options runtime --sign "$identity" --entitlements "$entitlements/widget.plist" "$widget"
codesign --force --options runtime --sign "$identity" --entitlements "$entitlements/app.plist" "$app"
codesign --verify --deep --strict "$app"
print "Built: $app"
