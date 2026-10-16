#!/bin/bash
#
# Builds the libntfs-3g bridge and runs the engine tests on fresh disposable
# images. Never touches physical devices.
#
# Usage: scripts/run-engine-tests.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/build/src/ntfs-3g-2026.9.28"
LIB="$REPO_ROOT/build/lib/libntfs-3g.a"
OUT="$REPO_ROOT/build/tests"

if [ ! -f "$LIB" ] || [ ! -d "$SRC/include/ntfs-3g" ]; then
    echo "error: ntfs-3g not built. Run scripts/build-libntfs.sh first." >&2
    exit 1
fi

mkdir -p "$OUT"

echo "==> compiling engine tests"
cc -std=gnu11 -O1 -g -Wall -Wextra \
    -mmacosx-version-min=26.0 \
    -DHAVE_CONFIG_H \
    -I"$SRC" \
    -I"$SRC/include" \
    -I"$SRC/include/ntfs-3g" \
    -o "$OUT/engine_tests" \
    "$REPO_ROOT/bridge/ntfs_bridge.c" \
    "$REPO_ROOT/tests/engine/test_engine.c" \
    "$LIB" \
    -framework CoreFoundation

echo "==> creating disposable images"
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$OUT/engine-cycle.img" >/dev/null
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$OUT/engine-dirty.img" >/dev/null
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$OUT/engine-hibernated.img" >/dev/null
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$OUT/engine-extra.img" >/dev/null

echo "==> running engine tests"
"$OUT/engine_tests" \
    "$OUT/engine-cycle.img" \
    "$OUT/engine-dirty.img" \
    "$OUT/engine-hibernated.img" \
    "$OUT/engine-extra.img"
