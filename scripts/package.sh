#!/bin/bash
# Builds a Release Couchwire.app and wraps it in a drag-to-Applications DMG.
#
#   scripts/package.sh                 ad-hoc signed (runs on this Mac; other Macs need
#                                      right-click > Open, or System Settings > Open Anyway)
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=couchwire scripts/package.sh
#                                      Developer ID signed, notarized and stapled
#                                      (profile from `xcrun notarytool store-credentials`)
#
# Output: build/release/Couchwire-<version>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DERIVED="$OUT/DerivedData"
IDENTITY="${SIGN_IDENTITY:--}"

cd "$ROOT"
xcodegen generate > /dev/null
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== Building Release"
xcodebuild -project Couchwire.xcodeproj -scheme Couchwire -configuration Release \
	-derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="$IDENTITY" OTHER_CODE_SIGN_FLAGS="--timestamp" \
	build > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
APP="$DERIVED/Build/Products/Release/Couchwire.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"

echo "== Checking the app is self-contained"
if otool -L "$APP/Contents/MacOS/Couchwire" | grep -E "/opt/homebrew|/usr/local"; then
	echo "Couchwire links a library outside the system; run scripts/build-deps.sh" >&2
	exit 1
fi
codesign --verify --deep --strict "$APP"
codesign -dv "$APP" 2>&1 | grep -E "^(Authority|Signature|CodeDirectory)" || true

echo "== Making the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Couchwire-$VERSION.dmg"
hdiutil create -volname "Couchwire $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG" > /dev/null
rm -rf "$STAGE"
if [ "$IDENTITY" != "-" ]; then
	codesign --sign "$IDENTITY" --timestamp "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
	echo "== Notarizing"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	xcrun stapler staple "$DMG"
fi

echo "Done: $DMG"
