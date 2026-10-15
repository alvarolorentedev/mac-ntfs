#!/bin/bash
#
# Builds the pinned upstream ntfs-3g into build/:
#   build/lib/libntfs-3g.a   static engine library (no FUSE linked)
#   build/bin/mkntfs         dev-only tool to create disposable test images
#
# Uses the official release tarball (ships a generated configure script), so
# only Xcode command line tools are required. No Homebrew at build or runtime.
#
set -euo pipefail

NTFS3G_VERSION="2026.9.28"
NTFS3G_URL="https://download.tuxera.com/opensource/ntfs-3g_ntfsprogs-${NTFS3G_VERSION}.tgz"
NTFS3G_SHA256="350d9415c59f7c3fa74e23985ad2d56423c6a168337368f672e2e362d8f295c8"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
SRC_PARENT="$BUILD_DIR/src"
SRC_DIR="$SRC_PARENT/ntfs-3g-${NTFS3G_VERSION}"
TARBALL="$SRC_PARENT/ntfs-3g_ntfsprogs-${NTFS3G_VERSION}.tgz"
LIB_OUT="$BUILD_DIR/lib/libntfs-3g.a"
BIN_OUT="$BUILD_DIR/bin/mkntfs"

for tool in curl tar make shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' is required" >&2
        exit 1
    fi
done

mkdir -p "$SRC_PARENT" "$BUILD_DIR/lib" "$BUILD_DIR/bin"

if [ ! -f "$TARBALL" ]; then
    echo "==> downloading ntfs-3g $NTFS3G_VERSION"
    curl -fsSL -o "$TARBALL" "$NTFS3G_URL"
fi

echo "==> verifying SHA-256"
actual_sha="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$actual_sha" != "$NTFS3G_SHA256" ]; then
    echo "error: SHA-256 mismatch" >&2
    echo "  expected: $NTFS3G_SHA256" >&2
    echo "  actual:   $actual_sha" >&2
    exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "==> extracting"
    tar -xzf "$TARBALL" -C "$SRC_PARENT"
fi

cd "$SRC_DIR"

if [ ! -f ./config.h ]; then
    echo "==> configuring (lib + ntfsprogs; FUSE driver disabled)"
    # --disable-ntfs-3g: never link or build the FUSE driver. MacNTFS calls
    # libntfs-3g directly from the FSKit module.
    ./configure \
        --disable-ntfs-3g \
        --disable-mount-helper \
        --disable-mtab \
        --enable-static \
        --disable-shared \
        CFLAGS="-O2 -fPIC"
fi

echo "==> building"
make -j"$(sysctl -n hw.ncpu)"

cp -f libntfs-3g/.libs/libntfs-3g.a "$LIB_OUT"
cp -f ntfsprogs/mkntfs "$BIN_OUT"

echo "==> installed"
echo "    $LIB_OUT"
echo "    $BIN_OUT"
