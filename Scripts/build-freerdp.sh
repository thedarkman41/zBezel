#!/bin/zsh
# Build a minimal STATIC FreeRDP for zBezel's remote-desktop path.
#
# zBezel needs RDP for exactly one thing: authenticate to a Windows box so a
# session exists, then drop it. The session survives as Disconnected, and
# `BezelAgent reclaim` moves it onto the physical console. No framebuffer, no
# input, no clipboard -- so almost everything FreeRDP can build is dead weight.
#
# Homebrew's build has all of it switched on: linking against it drags in six
# ffmpeg libraries, X11, uriparser and jansson, which then have to be bundled
# into the .app and re-signed on a volume that already fights over
# com.apple.FinderInfo. Building it ourselves with the extras off leaves static
# archives and nothing to ship.
#
# Output: build/freerdp/{include,lib}. Not committed -- run this once.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO/Sources/BezelApp.swift" ]] || { echo "not the Bezel repo: $REPO" >&2; exit 1; }

VERSION="3.30.0"
WORK="$REPO/build/freerdp-src"
PREFIX="$REPO/build/freerdp"
TARBALL="$(brew --cache)/freerdp--${VERSION}.tar.gz"

if [[ ! -f "$TARBALL" ]]; then
    echo "==> fetching source (checksum-verified by Homebrew)"
    brew fetch --build-from-source freerdp >/dev/null
fi

if [[ ! -d "$WORK/FreeRDP-${VERSION}" ]]; then
    echo "==> unpacking $VERSION"
    mkdir -p "$WORK"
    tar -xzf "$TARBALL" -C "$WORK"
fi

SRC="$WORK/FreeRDP-${VERSION}"
OPENSSL="$(brew --prefix openssl@3)"

# H.264 for the Control viewer (RemoteFX/NSCodec are built in; H.264/AVC444 is
# the better desktop codec but needs a decoder). openh264 is Cisco's, BSD, and
# small. WITH_OPENH264_LOADING means FreeRDP dlopens libopenh264.dylib at
# runtime rather than the app linking it: no dylib to bundle and re-sign on the
# file-provider volume, and the H.264 path simply stays dark if it is ever
# absent (RemoteFX still carries the picture). One dylib, loaded, versus the six
# ffmpeg libraries the stock build would drag in.
OPENH264="$(brew --prefix openh264 2>/dev/null || true)"
H264_FLAGS=()
if [[ -n "$OPENH264" && -f "$OPENH264/include/wels/codec_api.h" ]]; then
    H264_FLAGS=(-DWITH_OPENH264=ON -DWITH_OPENH264_LOADING=ON -DOPENH264_ROOT="$OPENH264")
    echo "==> openh264 found at $OPENH264 — enabling H.264 (runtime-loaded)"
else
    echo "==> openh264 not found — H.264 off (brew install openh264 to enable)"
fi

echo "==> configuring (static, no ffmpeg/X11/SDL/server)"
cmake -S "$SRC" -B "$SRC/build-static" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    "${H264_FLAGS[@]}" \
    -DWITH_SAMPLE=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_CLIENT_MAC=OFF \
    -DWITH_X11=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_DSP_FFMPEG=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_FUSE=OFF \
    -DWITH_LIBUSB=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_OSS=OFF \
    -DWITH_ALSA=OFF \
    -DWITH_FAAD2=OFF \
    -DWITH_FAAC=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_WEBVIEW=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_FIDO=OFF \
    -DWITH_MANPAGES=OFF \
    -DCHANNEL_URBDRC=OFF \
    -DCHANNEL_URBDRC_CLIENT=OFF \
    -DWITH_URIPARSER=OFF \
    -DWITH_AAD=OFF \
    -DOPENSSL_ROOT_DIR="$OPENSSL" \
    "$@"

echo "==> building"
cmake --build "$SRC/build-static" --parallel

echo "==> installing to $PREFIX"
cmake --install "$SRC/build-static" >/dev/null

# cmake installs the public libraries but leaves the channel "common" helpers
# in the build tree, even though libfreerdp-client3.a references their symbols
# (remdesk_*, rdpsnd_*). In a shared build the dylib would carry them; in a
# static one the link fails without them. Collect them alongside the rest.
echo "==> collecting channel helper archives cmake does not install"
find "$SRC/build-static" -name "lib*-common.a" -not -path "*/CMakeFiles/*" \
     -exec cp {} "$PREFIX/lib/" \;

echo
echo "Static archives:"
find "$PREFIX/lib" -name "*.a" -exec basename {} \; | sort
echo
echo "Any dylibs left (there should be none):"
find "$PREFIX/lib" -name "*.dylib" | head || true
