#!/bin/bash
# Builds a Release Couchwire.app and wraps it in a drag-to-Applications DMG.
#
#   scripts/package.sh                 ad-hoc signed (runs on this Mac; other Macs need
#                                      right-click > Open, or System Settings > Open Anyway)
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=couchwire scripts/package.sh
#                                      Developer ID signed, notarized and stapled
#                                      (profile from `xcrun notarytool store-credentials`)
#   PUBLISH=1 scripts/package.sh       also publishes the GitHub release on ElBeeHQ/Couchwire,
#                                      then commits and pushes the updated appcast.xml (the
#                                      app's update feed, read from main)
#
# Every DMG is signed with Couchwire's Sparkle EdDSA key (login keychain, account
# "couchwire") and added to the appcast. Bump CFBundleVersion (kept equal to the version, e.g. 0.1.1) in Info.plist for each release:
# Sparkle compares it to decide whether an update is newer. Release notes come from
# release-notes/<version>.md.
#
# Couchwire is AGPL-3.0 (with the OpenSSL exception), so every published DMG ships with its
# Corresponding Source: Couchwire-<version>-source.tar.gz (this repo and chiaki-ng at the
# commits built) and Couchwire-<version>-dependencies-source.tar (the exact upstream sources
# scripts/build-deps.sh builds, OpenSSL included). Publishing needs a clean working tree.
#
# Output in build/release: the DMG, appcast.xml and both source archives
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
DERIVED="$OUT/DerivedData"
IDENTITY="${SIGN_IDENTITY:--}"
ENTITLEMENTS="Couchwire/Couchwire.entitlements"
[ "$IDENTITY" != "-" ] && ENTITLEMENTS="Couchwire/Couchwire-DeveloperID.entitlements"
RELEASES_REPO="ElBeeHQ/Couchwire"
SPARKLE_ACCOUNT="couchwire"

cd "$ROOT"
# The source archive and the clean-tree check both need chiaki-ng as a real submodule checkout.
# In a worktree it's often a symlink to the main checkout's, which makes git fail on every
# submodule command, so stop here rather than publish incomplete source.
if [ -L Vendor/chiaki-ng ] || ! git submodule status --recursive > /dev/null; then
	echo "Vendor/chiaki-ng isn't a submodule checkout here (a symlink?). Package from the main checkout." >&2
	exit 1
fi
# On their own lines, so a failing git stops the script (set -e doesn't look inside a test).
STATUS="$(git status --porcelain --ignore-submodules=none)"
if [ "${PUBLISH:-}" = "1" ] && [ -n "$STATUS" ]; then
	echo "Commit your changes first: the published source must match the build." >&2
	exit 1
fi
xcodegen generate > /dev/null
rm -rf "$OUT"/*.dmg "$OUT"/*.tar* "$OUT/appcast.xml" "$OUT/dmg"  # keep DerivedData (and the Sparkle download)
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

echo "== Source archives (AGPL Corresponding Source)"
SRC_TAR="$OUT/Couchwire-$VERSION-source.tar.gz"
PARTS="$OUT/src-parts"
rm -rf "$PARTS"; mkdir -p "$PARTS"
git archive --prefix="Couchwire-$VERSION/" -o "$PARTS/0.tar" HEAD
n=1
# Every initialised submodule (chiaki-ng and the ones it builds from), at the commit used.
SUBMODULES="$(git submodule foreach --recursive --quiet 'echo "$displaypath"')"
while read -r sub; do
	git -C "$sub" archive --prefix="Couchwire-$VERSION/$sub/" -o "$PARTS/$n.tar" HEAD
	n=$((n + 1))
done <<< "$SUBMODULES"
tar -czf "$SRC_TAR" $(for f in "$PARTS"/*.tar; do echo "@$f"; done)
rm -rf "$PARTS"
# The archive must let anyone rebuild what's in the DMG: chiaki-ng and the patches on top of it.
LISTING="$(tar -tzf "$SRC_TAR")"
for f in Vendor/chiaki-ng/lib/src/remote/holepunch.c Vendor/chiaki-ng/third-party/nanopb/pb.h scripts/build-chiaki.sh; do
	grep -qx "Couchwire-$VERSION/$f" <<< "$LISTING" || { echo "The source archive is missing $f" >&2; exit 1; }
done
for p in patches/chiaki-ng/*.patch; do
	[ -f "$p" ] || continue
	grep -qx "Couchwire-$VERSION/$p" <<< "$LISTING" || { echo "The source archive is missing $p (commit it first)" >&2; exit 1; }
done
DEPS_TAR="$OUT/Couchwire-$VERSION-dependencies-source.tar"
[ -d build/deps/src ] || { echo "build/deps/src is missing; run scripts/build-deps.sh" >&2; exit 1; }
tar -cf "$DEPS_TAR" -C build/deps src
ls -lh "$SRC_TAR" "$DEPS_TAR" | awk '{print "   ", $5, $NF}'

echo "== Signing the update and writing the appcast"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
FEED="$OUT/feed"
rm -rf "$FEED"; mkdir -p "$FEED"
# Start from the published feed so earlier releases stay listed.
[ -f appcast.xml ] && cp appcast.xml "$FEED/appcast.xml"
NOTES="release-notes/$VERSION.md"
cp "$DMG" "$FEED/"
[ -f "$NOTES" ] && cp "$NOTES" "$FEED/$(basename "$DMG" .dmg).md"
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
	--download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/v$VERSION/" \
	--link "https://github.com/$RELEASES_REPO" "$FEED"
cp "$FEED/appcast.xml" "$OUT/appcast.xml"
rm -rf "$FEED"
grep -q "sparkle:edSignature" "$OUT/appcast.xml" || { echo "appcast has no EdDSA signature" >&2; exit 1; }

if [ "${PUBLISH:-}" = "1" ]; then
	[ -f "$NOTES" ] || { echo "Write $NOTES first." >&2; exit 1; }
	TITLE="Couchwire $VERSION"
	FIRST="$(head -1 "$NOTES")"
	[[ "$FIRST" == "# "* ]] && TITLE="${FIRST#\# }"
	echo "== Publishing v$VERSION to $RELEASES_REPO"
	gh release create "v$VERSION" "$DMG" "$SRC_TAR" "$DEPS_TAR" --repo "$RELEASES_REPO" --target "$(git rev-parse HEAD)" \
		--title "$TITLE" --notes-file <(tail -n +2 "$NOTES")
	echo "== Updating the update feed"
	cp "$OUT/appcast.xml" appcast.xml
	git add appcast.xml
	git -c user.name=ElBeeHQ -c user.email=hello@elbeehq.com commit -q -m "Add Couchwire $VERSION to the update feed"
	git push -q
fi

echo "Done: $DMG"
echo "      $OUT/appcast.xml"
