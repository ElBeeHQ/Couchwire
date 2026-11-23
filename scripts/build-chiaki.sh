#!/bin/bash
# Builds libchiaki (the PlayStation Remote Play protocol core from chiaki-ng)
# as a static library for the Couchwire macOS app, against the static dependencies
# from scripts/build-deps.sh (built first if missing), for macOS 14+.
#
# Build tools (Homebrew): cmake pkg-config protobuf
# A Python venv at .venv with `protobuf` is used for nanopb code generation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/chiaki"
DEPS="$ROOT/build/deps/prefix"

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

cmake -S "$ROOT/Vendor/chiaki-ng" -B "$BUILD" \
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
find "$BUILD" -name '*.a' -not -path "$BUILD/out/*" -print0 | xargs -0 libtool -static -o "$BUILD/out/libchiaki_all.a"
echo "libchiaki built: $BUILD/out/libchiaki_all.a"
