#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
CONFIGURATION="${CONFIGURATION:-release}"
VERSION=$(python3 -c 'import json; print(json.load(open("version.json"))["version"])')
BUILD_NUMBER=$(python3 -c 'import json; print(json.load(open("version.json"))["build"])')
swift build -c "$CONFIGURATION" --arch arm64 --disable-sandbox
APP="$PWD/dist/G-Clip.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
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
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
