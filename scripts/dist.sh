#!/usr/bin/env bash
# Builds dist/Arrow-<version>.dmg, signed with the team's Developer ID for
# distribution outside the App Store (hardened runtime).
#
#   TEAM=ABCDE12345 ./scripts/dist.sh             # signed
#   TEAM=ABCDE12345 NOTARIZE=1 ./scripts/dist.sh  # signed, notarized, stapled
#
# Signing and notarization go through the Apple account set up in Xcode
# (Settings ▸ Accounts): Xcode uses the team's cloud-managed Developer ID
# certificate, so none is needed in the Keychain.
set -euo pipefail

: "${TEAM:?set TEAM to the Apple Developer team ID}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
ARCHIVE="$BUILD/Arrow.xcarchive"
OPTIONS="$BUILD/ExportOptions.plist"
cd "$ROOT"

export_options() {
  cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>developer-id</string>
	<key>signingStyle</key><string>automatic</string>
	<key>teamID</key><string>$TEAM</string>
	<key>destination</key><string>$1</string>
</dict>
</plist>
EOF
}

xcodegen generate
rm -rf "$ARCHIVE"
xcodebuild -project Arrow.xcodeproj -scheme Arrow -configuration Release \
  -derivedDataPath "$BUILD/DerivedData" -archivePath "$ARCHIVE" archive \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="Apple Distribution" ENABLE_HARDENED_RUNTIME=YES

APP_DIR="$BUILD/export"
rm -rf "$APP_DIR"
if [ "${NOTARIZE:-0}" = 1 ]; then
  export_options upload
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "$BUILD/upload" -allowProvisioningUpdates
  # Apple usually answers within minutes; the notarized app is ready once
  # -exportNotarizedApp succeeds. Until then it fails with "is processing";
  # any other error (a rejected submission…) is final.
  for attempt in $(seq 1 120); do
    if output="$(xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$APP_DIR" 2>&1)"; then break; fi
    if ! grep -q "is processing" <<< "$output"; then
      echo "$output" >&2
      echo "error: notarization failed (xcrun notarytool history / log show Apple's report)" >&2
      exit 1
    fi
    echo "Waiting for Apple's notarization… ($((attempt / 2)) min)"
    sleep 30
  done
  [ -d "$APP_DIR/Arrow.app" ] || { echo "error: notarization still in progress after an hour" >&2; exit 1; }
  xcrun stapler validate "$APP_DIR/Arrow.app"
else
  export_options export
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
    -exportPath "$APP_DIR" -allowProvisioningUpdates
fi
codesign --verify --deep --strict "$APP_DIR/Arrow.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Arrow.app/Contents/Info.plist")"
STAGING="$BUILD/dmg"
DMG="$ROOT/dist/Arrow-$VERSION.dmg"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING" "$ROOT/dist"
ditto "$APP_DIR/Arrow.app" "$STAGING/Arrow.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname Arrow -srcfolder "$STAGING" -fs APFS -format ULMO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "$DMG"
