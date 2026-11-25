#!/bin/bash
# Builds libchiaki (the PlayStation Remote Play protocol core from chiaki-ng)
# as a static library for the Couchwire macOS app, against the static dependencies
# from scripts/build-deps.sh (built first if missing), for macOS 14+.
#
# Build tools (Homebrew): cmake pkg-config protobuf
# A Python venv at .venv with `protobuf` is used for nanopb code generation.
#
# Fixes Couchwire carries on top of chiaki-ng live in patches/chiaki-ng/*.patch. The
# submodule itself stays untouched (package.sh needs a clean tree): its source is copied
# to build/chiaki/src, the patches are applied there, and libchiaki is built from the copy.
# The library is stamped with the submodule (commits, nested submodules, local edits), the
# patches and this script, so changing any of them rebuilds it; otherwise this script
# returns straight away.
#
# When chiaki-ng takes one of the fixes upstream and the submodule moves past it, the
# build stops and says which patch to delete.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/chiaki"
SRC="$BUILD/src"
DEPS="$ROOT/build/deps/prefix"
LIB="$BUILD/out/libchiaki_all.a"
STAMP="$BUILD/out/stamp"

VENDOR="$ROOT/Vendor/chiaki-ng"
PATCHES=()
for p in "$ROOT"/patches/chiaki-ng/*.patch; do
	[ -f "$p" ] && PATCHES+=("$p")
done
# (bash 3.2 treats an empty array as unset under `set -u`, hence the ${…+…} forms.)
WANT="$(
	git -C "$VENDOR" rev-parse HEAD
	git -C "$VENDOR" submodule status --recursive
	git -C "$VENDOR" status --porcelain --ignore-submodules=none | shasum
	cat /dev/null ${PATCHES[@]+"${PATCHES[@]}"} "$0" | shasum
)"
if [ -f "$LIB" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$WANT" ]; then
	exit 0
fi

if [ ! -f "$DEPS/lib/libcurl.a" ]; then
	"$ROOT/scripts/build-deps.sh"
fi
# Only our own static deps: never let CMake or pkg-config find Homebrew's copies.
export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export MACOSX_DEPLOYMENT_TARGET=14.0

# chiaki-ng forces its deployment target to the build machine's macOS (read from sw_vers),
# because its own app bundles Homebrew's libraries. Ours are built for 14.0, so give its
# CMake a sw_vers that reports that instead of patching the submodule.
SHIM="$BUILD/shim"
mkdir -p "$SHIM"
printf '#!/bin/sh\necho %s\n' "$MACOSX_DEPLOYMENT_TARGET" > "$SHIM/sw_vers"
chmod +x "$SHIM/sw_vers"
export PATH="$SHIM:$PATH"

if [ ! -x "$ROOT/.venv/bin/python3" ]; then
	python3 -m venv "$ROOT/.venv"
	"$ROOT/.venv/bin/pip" install -q protobuf
fi

# The source copy, with Couchwire's patches applied. Files are compared by content and any
# that differ are written fresh (dates not kept), so a file a patch no longer touches is
# newer than its old object and gets rebuilt; untouched files keep their dates.
mkdir -p "$SRC"
rsync -rlp --checksum --delete --exclude .git "$VENDOR/" "$SRC/"
for p in ${PATCHES[@]+"${PATCHES[@]}"}; do
	name="${p#"$ROOT"/}"
	if (cd "$SRC" && patch -p1 -R --dry-run --force --quiet < "$p" > /dev/null 2>&1); then
		echo "error: chiaki-ng already has the fix in $name (taken upstream?). Delete $name and build again." >&2
		exit 1
	fi
	echo "Applying $name"
	# No fuzz: a patch that no longer fits exactly fails instead of landing in the wrong place.
	if ! (cd "$SRC" && patch -p1 --forward --fuzz=0 --no-backup-if-mismatch < "$p"); then
		echo "error: $name no longer applies to this chiaki-ng. Update it for the new submodule commit, or delete it if the fix is upstream." >&2
		exit 1
	fi
done

# A build folder configured from somewhere else (the submodule itself, before patches were
# carried) can't be reused: CMake refuses a different source folder, and old targets' archives
# would be merged into the library below. Start that build folder afresh.
if [ -f "$BUILD/CMakeCache.txt" ] && ! grep -qx "CMAKE_HOME_DIRECTORY:INTERNAL=$SRC" "$BUILD/CMakeCache.txt"; then
	find "$BUILD" -mindepth 1 -maxdepth 1 ! -name src ! -name shim ! -name out -exec rm -rf {} +
fi

cmake -S "$SRC" -B "$BUILD" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
	-DCHIAKI_ENABLE_TESTS=OFF \
	-DCHIAKI_ENABLE_CLI=OFF \
	-DCHIAKI_ENABLE_GUI=OFF \
	-DCHIAKI_ENABLE_SETSU=OFF \
	-DCHIAKI_ENABLE_STEAMDECK_NATIVE=OFF \
	-DCHIAKI_ENABLE_FFMPEG_DECODER=OFF \
	-DCHIAKI_ENABLE_PI_DECODER=OFF \
	-DCHIAKI_ENABLE_SPEEX=OFF \
	-DCHIAKI_ENABLE_STEAM_SHORTCUT=OFF \
	-DCHIAKI_USE_SYSTEM_CURL=ON \
	-DCHIAKI_USE_SYSTEM_NANOPB=OFF \
	-DCHIAKI_USE_SYSTEM_JERASURE=OFF \
	-DPYTHON_EXECUTABLE="$ROOT/.venv/bin/python3" \
	-DOPENSSL_ROOT_DIR="$DEPS" \
	-DOPENSSL_USE_STATIC_LIBS=ON \
	-DCMAKE_PREFIX_PATH="$DEPS" \
	-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew

cmake --build "$BUILD" --target chiaki-lib -j "$(sysctl -n hw.ncpu)"

# Merge libchiaki and its vendored static deps (jerasure, gf-complete, nanopb)
# into one archive the Xcode project links against.
mkdir -p "$BUILD/out"
rm -f "$BUILD/out/libchiaki_all.a"
find "$BUILD" -name '*.a' -not -path "$BUILD/out/*" -not -path "$SRC/*" -print0 | xargs -0 libtool -static -o "$BUILD/out/libchiaki_all.a"
echo "$WANT" > "$STAMP"
echo "libchiaki built: $LIB (${#PATCHES[@]} patch(es) applied)"
