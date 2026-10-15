#!/bin/bash
#
# Creates a disposable NTFS image for development and validation only.
# Never point this at a physical device.
#
# Usage: scripts/make-test-image.sh [size-mb] [output-path]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MKNTFS="$REPO_ROOT/build/bin/mkntfs"
SIZE_MB="${1:-64}"
OUT="${2:-$REPO_ROOT/build/test-images/ntfs-test-${SIZE_MB}mb.img}"

if [ ! -x "$MKNTFS" ]; then
    echo "error: $MKNTFS not found. Run scripts/build-libntfs.sh first." >&2
    exit 1
fi

case "$OUT" in
    /dev/*)
        echo "error: refusing to write a test image to a device path: $OUT" >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
mkfile -n "${SIZE_MB}m" "$OUT"

SECTORS=$((SIZE_MB * 1024 * 1024 / 512))
"$MKNTFS" -F -q -L MacNTFSTest -s 512 "$OUT" "$SECTORS"

echo "$OUT"
