#!/usr/bin/env bash
# Builds PushToTalk and packages it into PushToTalk.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="PushToTalk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/PushToTalk "$APP/Contents/MacOS/PushToTalk"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PushToTalk</string>
  <key>CFBundleDisplayName</key><string>PushToTalk</string>
  <key>CFBundleIdentifier</key><string>com.crittermike.PushToTalk</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleExecutable</key><string>PushToTalk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>PushToTalk toggles your microphone mute state.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so TCC remembers Accessibility permission across rebuilds.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $(pwd)/$APP"
echo "Run:  open ./$APP   (or drag to /Applications)"
