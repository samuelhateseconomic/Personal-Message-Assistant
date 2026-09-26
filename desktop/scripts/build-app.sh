#!/bin/sh
set -eu
DESKTOP_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${IMSG_BUILD_DIR:-"$DESKTOP_ROOT/.build/native"}
swift build --package-path "$DESKTOP_ROOT" --scratch-path "$BUILD_DIR"
BIN_DIR=$(swift build --package-path "$DESKTOP_ROOT" --scratch-path "$BUILD_DIR" --show-bin-path)
APP_PATH="$DESKTOP_ROOT/.build/Message Assistant Demo.app"
mkdir -p "$APP_PATH/Contents/MacOS"
cp "$BIN_DIR/MessageAssistant" "$APP_PATH/Contents/MacOS/MessageAssistant"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MessageAssistant</string>
<key>CFBundleIdentifier</key><string>local.messageassistant.prototype</string>
<key>CFBundleName</key><string>Message Assistant Demo</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.1</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSContactsUsageDescription</key><string>Read contacts and save reviewed contact changes to the account you choose. Connection type and private assistant notes stay in this app.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$APP_PATH"
printf '%s\n' "$APP_PATH"
