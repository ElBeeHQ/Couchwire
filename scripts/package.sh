#!/bin/bash
# Builds a Release Couchwire.app and wraps it in a drag-to-Applications DMG.
#
#   scripts/package.sh                 ad-hoc signed (runs on this Mac; other Macs need
#                                      right-click > Open, or System Settings > Open Anyway)
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=couchwire scripts/package.sh
#                                      Developer ID signed, notarized and stapled
#                                      (profile from `xcrun notarytool store-credentials`)
#   PUBLISH=1 scripts/package.sh       also uploads the DMG and appcast as a GitHub release
#                                      on ElBeeHQ/couchwire-releases (the app's update feed)
#
# Every DMG is signed with Couchwire's Sparkle EdDSA key (login keychain, account
# "couchwire") and gets an appcast.xml. Bump CFBundleVersion in Info.plist for each release:
# Sparkle compares it to decide whether an update is newer.
#
# Output: build/release/Couchwire-<version>.dmg and build/release/appcast.xml
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DERIVED="$OUT/DerivedData"
IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="Couchwire/Couchwire.entitlements"
[ "$IDENTITY" != "-" ] && ENTITLEMENTS="Couchwire/Couchwire-DeveloperID.entitlements"
RELEASES_REPO="ElBeeHQ/couchwire-releases"
SPARKLE_ACCOUNT="couchwire"

cd "$ROOT"
xcodegen generate > /dev/null
rm -rf "$OUT"/*.dmg "$OUT/appcast.xml" "$OUT/dmg"  # keep DerivedData (and the Sparkle download)
mkdir -p "$OUT"

echo "== Building Release"
xcodebuild -project Couchwire.xcodeproj -scheme Couchwire -configuration Release \
	-derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" OTHER_CODE_SIGN_FLAGS="--timestamp" \
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

echo "== Signing the update and writing the appcast"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
FEED="$OUT/feed"
mkdir -p "$FEED"
mv "$DMG" "$FEED/"
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" \
	--download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/v$VERSION/" \
	-o "$OUT/appcast.xml" "$FEED"
mv "$FEED/$(basename "$DMG")" "$DMG"
rm -rf "$FEED"
grep -q "sparkle:edSignature" "$OUT/appcast.xml" || { echo "appcast has no EdDSA signature" >&2; exit 1; }

if [ "${PUBLISH:-}" = "1" ]; then
	echo "== Publishing v$VERSION to $RELEASES_REPO"
	gh release create "v$VERSION" "$DMG" "$OUT/appcast.xml" --repo "$RELEASES_REPO" \
		--title "Couchwire $VERSION" --notes "Couchwire $VERSION"
fi

echo "Done: $DMG"
echo "      $OUT/appcast.xml"
