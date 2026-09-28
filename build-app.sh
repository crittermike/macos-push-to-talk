#!/usr/bin/env bash
# Builds PushToTalk into a new local bundle (default: "Push To Talk.app").
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-Push To Talk.app}"
if [[ $# -gt 1 || "$APP" != *.app || "$APP" == */* || "$APP" == .* || "$APP" == -* ]]; then
  echo "Usage: ./build-app.sh [local-bundle-name.app]" >&2
  exit 2
fi
if [[ -e "$APP" || -L "$APP" ]]; then
  echo "Refusing to overwrite $(pwd)/$APP. Choose a new local bundle name." >&2
  exit 1
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/PushToTalk" "$APP/Contents/MacOS/PushToTalk"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Push To Talk</string>
  <key>CFBundleDisplayName</key><string>Push To Talk</string>
  <key>CFBundleIdentifier</key><string>com.crittermike.PushToTalk</string>
  <key>CFBundleVersion</key><string>6</string>
  <key>CFBundleShortVersionString</key><string>0.4.2</string>
  <key>CFBundleExecutable</key><string>PushToTalk</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Legacy mode controls system microphone mute and volume. Teams mode uses Accessibility.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign for local execution. Rebuilds may require regranting Accessibility.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $(pwd)/$APP"
echo "Quit any older Push To Talk app through its menu before opening this build."
echo "Run:  open \"$(pwd)/$APP\""
