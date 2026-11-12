#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION=$(python3 -c 'import json; print(json.load(open("version.json"))["version"])')
BUILD_NUMBER=$(python3 -c 'import json; print(json.load(open("version.json"))["build"])')
swift build -c "$CONFIGURATION" --arch arm64 --disable-sandbox
APP="$PWD/dist/G-Clip.app"
SPARKLE="$PWD/.build/artifacts/sparkle/Sparkle"
PUBLIC_KEY=$(tr -d '\r\n' < updates/public-key.txt)
# A clean bundle prevents stale resources and signatures surviving rebuilds.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp Assets/GClip.icns "$APP/Contents/Resources/GClip.icns"
cp ".build/$CONFIGURATION/GClip" "$APP/Contents/MacOS/GClip"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.gclip.manager</string>
<key>CFBundleIconFile</key><string>GClip</string>
<key>CFBundleName</key><string>G-Clip</string>
<key>CFBundleDisplayName</key><string>G-Clip</string>
<key>CFBundleExecutable</key><string>GClip</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>SUFeedURL</key><string>https://github.com/costa37/g-clipboard-manager/releases/latest/download/appcast.xml</string>
<key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUEnableSystemProfiling</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
