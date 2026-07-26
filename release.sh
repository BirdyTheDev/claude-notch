#!/bin/bash
# Signs, notarises and packages a release DMG.
#
# One-time setup:
#   1. Apple Developer Program membership (the free tier cannot issue Developer ID certs).
#   2. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application.
#   3. An app-specific password from appleid.apple.com, then:
#        xcrun notarytool store-credentials notary \
#          --apple-id you@example.com --team-id TEAMID --password app-specific-password
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="Claude Notch"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')}"
PROFILE="${NOTARY_PROFILE:-notary}"
STAGE="$(mktemp -d)"
VERSION="$(grep '^VERSION=' build.sh | cut -d'"' -f2)"
DMG="dist/ClaudeNotch-$VERSION.dmg"

[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found."; exit 1; }
echo "-> identity: $IDENTITY"

./build.sh "$STAGE"

echo "-> signing"
codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" "$STAGE/$APP_NAME.app"
codesign --verify --deep --strict --verbose=2 "$STAGE/$APP_NAME.app"

echo "-> building dmg"
mkdir -p dist
rm -f "$DMG"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" "$DMG"

echo "-> notarising (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

rm -rf "$STAGE"
echo "OK  $DMG"
