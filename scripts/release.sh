#!/usr/bin/env bash
set -euo pipefail

# Signed and notarized release. Requirements:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE="spotifylite-notary"  # created with `xcrun notarytool store-credentials`
# Optional: VERSION=0.1.0

: "${DEVELOPER_ID:?Set DEVELOPER_ID to the Developer ID Application identity}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to the notarytool profile}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT/project.yml")}" 
BUILD_DIR="$ROOT/build/release"
ARCHIVE="$BUILD_DIR/SpotifyLite.xcarchive"
APP="$ARCHIVE/Products/Applications/SpotifyLite.app"
DMG="$BUILD_DIR/SpotifyLite-$VERSION.dmg"
STAGING="$BUILD_DIR/dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$STAGING"
cd "$ROOT"

xcodegen generate
xcodebuild archive \
  -project SpotifyLite.xcodeproj \
  -scheme SpotifyLite \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
  ONLY_ACTIVE_ARCH=NO

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --type execute --verbose=2 "$APP" || true

# Notarize and staple the app before putting it in the DMG.
ditto -c -k --keepParent "$APP" "$BUILD_DIR/SpotifyLite.zip"
xcrun notarytool submit "$BUILD_DIR/SpotifyLite.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "SpotifyLite" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG"
codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Release ready: $DMG"
