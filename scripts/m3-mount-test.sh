#!/bin/bash
#
# M3 gate: mounted read/write validation through the FSKit module on
# disposable images only. Verifies:
#   1. read/write mount (platform default) supports create, write, rename,
#      unlink with content hash verification after a remount
#   2. an explicit read-only mount ("rdonly") refuses writes
#   3. a dirty volume mounts read-only even for a read/write request (safety)
#   4. a hibernated volume mounts read-only even for a read/write request
#
# Never touches physical disks: devices come from attaching raw image files
# and every BSD name is validated before use.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/build/DerivedData/Build/Products/Debug/MacNTFS.app"
ENGINE_TESTS="$REPO_ROOT/build/tests/engine_tests"
OUT="$REPO_ROOT/build/tests"
MOUNTPOINT="${MOUNTPOINT:-$REPO_ROOT/build/mnt}"
SUDO=""
failures=0

note() { printf '\n== %s\n' "$1"; }
pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

cleanup() {
    if mount | grep -q -- "$MOUNTPOINT"; then
        umount "$MOUNTPOINT" 2>/dev/null || $SUDO umount "$MOUNTPOINT" 2>/dev/null
    fi
    if [ -n "${DEV:-}" ]; then
        hdiutil detach "$DEV" >/dev/null 2>&1
        DEV=""
    fi
}
trap cleanup EXIT

attach_image() {
    local image="$1"
    local out
    out="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$image")"
    local device
    device="$(printf '%s\n' "$out" | awk 'NR==1 {print $1}')"
    if ! [[ "$device" =~ ^/dev/disk[0-9]+$ ]]; then
        echo "error: unexpected device name from hdiutil: '$device'" >&2
        exit 1
    fi
    DEV="$device"
    echo "$DEV"
}

mount_volume() {
    local device="$1"
    shift
    mkdir -p "$MOUNTPOINT"
    if mount -F -t macntfs "$@" "$device" "$MOUNTPOINT" 2>/dev/null; then
        return 0
    fi
    if sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
        $SUDO mount -F -t macntfs "$@" "$device" "$MOUNTPOINT"
        return $?
    fi
    return 1
}

unmount_volume() {
    if ! umount "$MOUNTPOINT" 2>/dev/null; then
        $SUDO umount "$MOUNTPOINT" 2>/dev/null || {
            fail "unmount failed"
            return 1
        }
    fi
    return 0
}

note "preflight"
if [ ! -d "$APP" ]; then
    echo "error: app not built. Run ./scripts/build-signed.sh" >&2
    exit 1
fi
if [ ! -x "$ENGINE_TESTS" ]; then
    echo "engine test binary missing; running engine tests first"
    "$REPO_ROOT/scripts/run-engine-tests.sh" >/dev/null 2>&1 || {
        echo "error: engine tests failed; fix those first" >&2
        exit 1
    }
fi
mkdir -p "$OUT" "$MOUNTPOINT"

note "signature"
codesign --verify --strict "$APP" 2>/dev/null || fail "app signature invalid"

# ---------------------------------------------------------------------------
note "1. read/write mount: create, write, rename, unlink, remount verify"

RW_IMAGE="$OUT/m3-rw.img"
"$REPO_ROOT/scripts/make-test-image.sh" 128 "$RW_IMAGE" >/dev/null
DEV="$(attach_image "$RW_IMAGE")"
echo "attached $DEV for $RW_IMAGE"

if mount_volume "$DEV"; then
    if touch "$MOUNTPOINT/rw-probe" 2>/dev/null; then
        pass "mounted read-write (probe write succeeded)"
        rm -f "$MOUNTPOINT/rw-probe"
    else
        fail "writes are refused on a read/write mount"
    fi

    mkdir -p "$MOUNTPOINT/hello-dir" && pass "mkdir" || fail "mkdir"
    dd if=/dev/urandom of="$MOUNTPOINT/hello-dir/blob.bin" bs=64k count=16 2>/dev/null \
        && pass "write 1 MiB" || fail "write 1 MiB"
    EXPECT_HASH="$(shasum -a 256 "$MOUNTPOINT/hello-dir/blob.bin" 2>/dev/null | awk '{print $1}')"
    echo "macntfs" > "$MOUNTPOINT/note.txt" && pass "write note.txt" || fail "write note.txt"
    mv "$MOUNTPOINT/note.txt" "$MOUNTPOINT/renamed.txt" && pass "rename" || fail "rename"
    [ -f "$MOUNTPOINT/renamed.txt" ] && pass "renamed file present" || fail "renamed file missing"
    rm "$MOUNTPOINT/renamed.txt" && pass "unlink" || fail "unlink"
    [ ! -e "$MOUNTPOINT/renamed.txt" ] && pass "unlinked file gone" || fail "unlinked file still present"
    sync
    unmount_volume && pass "unmounted after writes"
else
    fail "read/write mount failed"
fi

if mount_volume "$DEV" -o rdonly; then
    if [ -f "$MOUNTPOINT/hello-dir/blob.bin" ]; then
        GOT_HASH="$(shasum -a 256 "$MOUNTPOINT/hello-dir/blob.bin" | awk '{print $1}')"
        if [ "$GOT_HASH" = "$EXPECT_HASH" ]; then
            pass "content survived remount (sha256 match)"
        else
            fail "content mismatch after remount"
        fi
    else
        fail "blob.bin missing after remount"
    fi
    [ ! -e "$MOUNTPOINT/renamed.txt" ] && pass "unlink persisted" || fail "unlinked file came back"
    if echo data > "$MOUNTPOINT/should-fail.txt" 2>/dev/null; then
        fail "write succeeded on a mount that must be read-only"
        rm -f "$MOUNTPOINT/should-fail.txt"
    else
        pass "writes refused on the explicit read-only mount"
    fi
    unmount_volume && pass "unmounted remount check"
else
    fail "read-only remount failed"
fi
hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""

# ---------------------------------------------------------------------------
note "2. dirty volume: read/write request must fall back to read-only"

DIRTY_IMAGE="$OUT/m3-dirty.img"
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$DIRTY_IMAGE" >/dev/null
"$ENGINE_TESTS" --make-dirty "$DIRTY_IMAGE" >/dev/null || fail "could not craft dirty fixture"
DEV="$(attach_image "$DIRTY_IMAGE")"
if mount_volume "$DEV"; then
    if echo data > "$MOUNTPOINT/should-fail.txt" 2>/dev/null; then
        fail "dirty volume accepted writes"
        rm -f "$MOUNTPOINT/should-fail.txt"
    else
        pass "dirty volume mounted read-only (writes refused)"
    fi
    unmount_volume && pass "unmounted dirty volume"
else
    fail "dirty volume mount failed entirely (should mount read-only)"
fi
hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""

# ---------------------------------------------------------------------------
note "3. hibernated volume: read/write request must fall back to read-only"

HIB_IMAGE="$OUT/m3-hibernated.img"
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$HIB_IMAGE" >/dev/null
"$ENGINE_TESTS" --make-hibernated "$HIB_IMAGE" >/dev/null || fail "could not craft hibernated fixture"
DEV="$(attach_image "$HIB_IMAGE")"
if mount_volume "$DEV"; then
    if echo data > "$MOUNTPOINT/should-fail.txt" 2>/dev/null; then
        fail "hibernated volume accepted writes"
        rm -f "$MOUNTPOINT/should-fail.txt"
    else
        pass "hibernated volume mounted read-only (writes refused)"
    fi
    unmount_volume && pass "unmounted hibernated volume"
else
    fail "hibernated volume mount failed entirely (should mount read-only)"
fi
hdiutil detach "$DEV" >/dev/null 2>&1; DEV=""

# ---------------------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
    printf '\nM3 GATE: FAILED (%d failures)\n' "$failures"
    "$REPO_ROOT/scripts/fskit-diagnose.sh" >/dev/null 2>&1 || true
    exit 1
fi
printf '\nM3 GATE: PASSED — read/write through the FSKit module verified on disposable images\n'
