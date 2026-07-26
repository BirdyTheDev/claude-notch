#!/bin/bash
# Builds Claude Notch and drops the .app into /Applications.
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Notchpad"
BUNDLE_ID="com.notchpad.app"
VERSION="2.2.0"
DEST="${1:-/Applications}"
APP="$DEST/$APP_NAME.app"
ICNS=".build/AppIcon.icns"

echo "-> building (release)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Notchpad"

# The icon is rendered from the same vector the mascot uses.
if [ ! -f "$ICNS" ] || [ Sources/Notchpad/ClaudeMark.swift -nt "$ICNS" ] || [ Support/make-icon.swift -nt "$ICNS" ]; then
    echo "-> rendering icon"
    TMP="$(mktemp -d)"
    cp Support/make-icon.swift "$TMP/main.swift"
    swiftc -O "$TMP/main.swift" Sources/Notchpad/ClaudeMark.swift -o "$TMP/make-icon"
    "$TMP/make-icon" "$TMP/AppIcon.iconset" >/dev/null
    iconutil -c icns "$TMP/AppIcon.iconset" -o "$ICNS"
    rm -rf "$TMP"
fi

echo "-> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Support/notchpad-hook.py "$APP/Contents/Resources/"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Shows your next events in the notch.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Lets you control the Music app from the notch.</string>
</dict>
</plist>
PLIST

echo "-> signing (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ $APP  ($VERSION)"
