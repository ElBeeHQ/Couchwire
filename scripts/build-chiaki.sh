#!/bin/bash
# Builds libchiaki (the PlayStation Remote Play protocol core from chiaki-ng)
# as a static library for the PSStream macOS app.
#
# Prereqs (Homebrew): cmake pkg-config protobuf json-c miniupnpc libevent curl openssl opus
# A Python venv at .venv with `protobuf` is used for nanopb code generation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BREW="$(brew --prefix)"
BUILD="$ROOT/build/chiaki"

if [ ! -x "$ROOT/.venv/bin/python3" ]; then
	python3 -m venv "$ROOT/.venv"
	"$ROOT/.venv/bin/pip" install -q protobuf
fi

cmake -S "$ROOT/Vendor/chiaki-ng" -B "$BUILD" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
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
	-DOPENSSL_ROOT_DIR="$BREW/opt/openssl" \
	-DCMAKE_PREFIX_PATH="$BREW;$BREW/opt/curl;$BREW/opt/openssl"

cmake --build "$BUILD" --target chiaki-lib -j "$(sysctl -n hw.ncpu)"

# Merge libchiaki and its vendored static deps (jerasure, gf-complete, nanopb)
# into one archive the Xcode project links against.
mkdir -p "$BUILD/out"
rm -f "$BUILD/out/libchiaki_all.a"
find "$BUILD" -name '*.a' -not -path "$BUILD/out/*" -print0 | xargs -0 libtool -static -o "$BUILD/out/libchiaki_all.a"
echo "libchiaki built: $BUILD/out/libchiaki_all.a"
