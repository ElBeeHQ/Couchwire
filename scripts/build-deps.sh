#!/bin/bash
# Builds libchiaki's third-party dependencies from source as static arm64 libraries for
# macOS 14+, so Couchwire is self-contained (no Homebrew at runtime) and runs on every
# macOS version it supports. Homebrew's own static archives target the host's macOS only.
#
# Output: build/deps/prefix/{include,lib}. Sources are downloaded once into build/deps/src
# and checked against the SHA-256s below (OpenSSL's matches its published checksum).
#
# Build tools needed: cmake, pkg-config, perl (all present with Xcode + Homebrew cmake).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/build/deps"
SRC="$DEPS/src"
WORK="$DEPS/work"
PREFIX="$DEPS/prefix"
export MACOSX_DEPLOYMENT_TARGET=14.0
ARCH=arm64
JOBS="$(sysctl -n hw.ncpu)"
CFLAGS_COMMON="-arch $ARCH -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"

# name | url | sha256
SOURCES=(
	"openssl-4.1.0.tar.gz|https://github.com/openssl/openssl/releases/download/openssl-4.1.0/openssl-4.1.0.tar.gz|50c17baf54cb008f6ce42d50deb4b28050a1aad711636cabd4b241c7e90cc2fd"
	"opus-1.5.2.tar.gz|https://github.com/xiph/opus/releases/download/v1.5.2/opus-1.5.2.tar.gz|65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1"
	"curl-8.23.0.tar.xz|https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.xz|8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5"
	"libevent-2.1.13-stable.tar.gz|https://github.com/libevent/libevent/releases/download/release-2.1.13-stable/libevent-2.1.13-stable.tar.gz|f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"
	"json-c-0.19-nodoc.tar.gz|https://github.com/json-c/json-c/releases/download/json-c-0.19-20260627/json-c-0.19-nodoc.tar.gz|704927172443309a8efeb162060bb215548e1286e5568514007dd2cc35a0a164"
	"miniupnpc-2.3.5.tar.gz|https://github.com/miniupnp/miniupnp/releases/download/miniupnpc_2_3_5/miniupnpc-2.3.5.tar.gz|b9a1e57233216c5f62572de6d628e73e910f50cdb71e9c0eb89b169ce154d256"
)

mkdir -p "$SRC" "$WORK" "$PREFIX"

fetch() { # name url sha -> extracted dir path on stdout
	local name="$1" url="$2" sha="$3"
	if [ ! -f "$SRC/$name" ]; then
		echo "Downloading $name" >&2
		curl -fsSL -o "$SRC/$name.part" "$url"
		mv "$SRC/$name.part" "$SRC/$name"
	fi
	echo "$sha  $SRC/$name" | shasum -a 256 -c --quiet - >&2
	local dir="$WORK/${name%.tar.*}"
	rm -rf "$dir"
	mkdir -p "$dir"
	tar -xf "$SRC/$name" -C "$dir" --strip-components 1
	echo "$dir"
}

src_for() { for s in "${SOURCES[@]}"; do [[ "$s" == "$1"* ]] && { IFS='|' read -r n u h <<< "$s"; fetch "$n" "$u" "$h"; return; }; done; echo "unknown $1" >&2; exit 1; }

cmake_build() { # dir [cmake args...]
	local dir="$1"; shift
	cmake -S "$dir" -B "$dir/_build" -G "Unix Makefiles" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES=$ARCH \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET \
		-DCMAKE_INSTALL_PREFIX="$PREFIX" \
		-DCMAKE_PREFIX_PATH="$PREFIX" \
		-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		"$@" > "$dir/_cmake.log"
	cmake --build "$dir/_build" -j "$JOBS" > "$dir/_build.log"
	cmake --install "$dir/_build" > /dev/null
}

echo "== OpenSSL"
d="$(src_for openssl)"
(cd "$d" && ./Configure darwin64-arm64-cc no-shared no-tests no-docs no-apps \
	--prefix="$PREFIX" --libdir=lib --openssldir=/etc/ssl "-mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET" > _configure.log \
	&& make -j "$JOBS" > _build.log && make install_sw > /dev/null)

echo "== Opus"
d="$(src_for opus)"
cmake_build "$d" -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF -DBUILD_TESTING=OFF

echo "== json-c"
d="$(src_for json-c)"
cmake_build "$d" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_TESTING=OFF -DBUILD_APPS=OFF -DDISABLE_EXTRA_LIBS=ON

echo "== miniupnpc"
d="$(src_for miniupnpc)"
cmake_build "$d" -DUPNPC_BUILD_SHARED=OFF -DUPNPC_BUILD_STATIC=ON -DUPNPC_BUILD_TESTS=OFF -DUPNPC_BUILD_SAMPLE=OFF

echo "== libevent"
d="$(src_for libevent)"
cmake_build "$d" -DEVENT__LIBRARY_TYPE=STATIC -DEVENT__DISABLE_OPENSSL=ON -DEVENT__DISABLE_MBEDTLS=ON \
	-DEVENT__DISABLE_TESTS=ON -DEVENT__DISABLE_SAMPLES=ON -DEVENT__DISABLE_BENCHMARK=ON -DEVENT__DISABLE_REGRESS=ON

echo "== curl"
d="$(src_for curl)"
# HTTP(S) and WebSockets only (libchiaki's PSN holepunch), OpenSSL for TLS, macOS's CA bundle.
cmake_build "$d" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
	-DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
	-DHTTP_ONLY=ON -DCURL_USE_OPENSSL=ON -DOPENSSL_ROOT_DIR="$PREFIX" -DOPENSSL_USE_STATIC_LIBS=ON \
	-DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DUSE_APPLE_IDN=OFF \
	-DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_ZLIB=ON -DCURL_DISABLE_LDAP=ON \
	-DCURL_CA_BUNDLE=/etc/ssl/cert.pem -DCURL_CA_PATH=none

echo "Dependencies built in $PREFIX"
