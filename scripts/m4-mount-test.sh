#!/bin/bash
#
# M4 gate: drives the app's mounting code (the exact code the menu bar uses)
# headlessly against disposable images.
#
# Verifies: listing through Disk Arbitration, read-only mount with writes
# refused, unmount, read/write mount with writes and readback, read-only
# remount, eject, and diagnostics export. Never touches physical disks.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$REPO_ROOT/build/DerivedData/Build/Products/Debug/MacNTFS.app"
APP="$APP_BUNDLE/Contents/MacOS/MacNTFS"
OUT="$REPO_ROOT/build/tests"
IMG="$OUT/m4-cli.img"
failures=0
BSD=""
DEV=""

note() { printf '\n== %s\n' "$1"; }
pass() { printf 'ok: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }

cleanup() {
    if [ -n "$BSD" ]; then
        "$APP" --unmount "$BSD" >/dev/null 2>&1 || true
    fi
    if [ -n "$DEV" ]; then
        hdiutil detach "$DEV" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

note "preflight"
if [ ! -x "$APP" ]; then
    echo "error: app not built. Run ./scripts/build-signed.sh" >&2
    exit 1
fi
codesign --verify --strict "$APP_BUNDLE" 2>/dev/null || fail "app signature invalid"
mkdir -p "$OUT"

note "1. list"
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$IMG" >/dev/null
DEV="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" | awk 'NR==1 {print $1}')"
if ! [[ "$DEV" =~ ^/dev/disk[0-9]+$ ]]; then
    echo "error: unexpected device name '$DEV'" >&2
    exit 1
fi
BSD="${DEV#/dev/}"
if "$APP" --list-volumes | grep -q "^$BSD	"; then
    pass "volume $BSD listed"
else
    fail "volume $BSD not listed by --list-volumes"
fi

note "2. system mount path (FSKit maintenance check regression)"
if diskutil mount readOnly "$DEV" >/dev/null 2>&1; then
    sleep 1
    if mount | grep -q "${DEV#/dev/}"; then
        pass "diskutil readOnly mount works (system check path)"
    else
        fail "diskutil reported success but nothing is mounted"
    fi
    diskutil unmount "$DEV" >/dev/null 2>&1 || fail "diskutil unmount failed"
else
    fail "diskutil readOnly mount failed (FSKit check regression)"
fi

note "3. mount read-only (default action) and write refusal"
MOUNT_POINT="$("$APP" --mount "$BSD" 2>/tmp/m4-mount-err.txt)"
if [ -n "$MOUNT_POINT" ] && mount | grep -q -- "$MOUNT_POINT"; then
    pass "mounted at $MOUNT_POINT"
else
    fail "mount failed: $(cat /tmp/m4-mount-err.txt)"
fi
if mount | grep -- "$MOUNT_POINT" | grep -q "read-only"; then
    pass "mount table reports read-only"
else
    fail "mount table does not report read-only"
fi
if touch "$MOUNT_POINT/should-fail.txt" 2>/dev/null; then
    fail "write succeeded on a read-only mount"
    rm -f "$MOUNT_POINT/should-fail.txt"
else
    pass "writes refused on read-only mount"
fi
if "$APP" --unmount "$BSD" >/dev/null 2>&1; then
    pass "unmounted"
else
    fail "unmount failed"
fi

note "4. mount read/write, write and read back"
MOUNT_POINT="$("$APP" --mount "$BSD" --rw 2>/tmp/m4-mount-err.txt)"
if [ -n "$MOUNT_POINT" ] && mount | grep -q -- "$MOUNT_POINT"; then
    if mount | grep -- "$MOUNT_POINT" | grep -q "read-only"; then
        fail "read-write mount came back read-only"
    else
        pass "mounted read-write at $MOUNT_POINT"
    fi
else
    fail "read-write mount failed: $(cat /tmp/m4-mount-err.txt)"
fi
if echo "macntfs" > "$MOUNT_POINT/cli-note.txt" 2>/dev/null; then
    pass "wrote cli-note.txt"
else
    fail "write failed on read-write mount"
fi
"$APP" --unmount "$BSD" >/dev/null 2>&1 || fail "unmount after writes failed"

note "5. read-only remount verifies persistence"
MOUNT_POINT="$("$APP" --mount "$BSD" 2>/dev/null)"
if [ -f "$MOUNT_POINT/cli-note.txt" ] && [ "$(cat "$MOUNT_POINT/cli-note.txt")" = "macntfs" ]; then
    pass "file persisted across remount"
else
    fail "file missing or corrupted after remount"
fi
if touch "$MOUNT_POINT/nope" 2>/dev/null; then
    fail "write succeeded on read-only remount"
    rm -f "$MOUNT_POINT/nope"
else
    pass "writes refused on read-only remount"
fi
"$APP" --unmount "$BSD" >/dev/null 2>&1 || fail "unmount before eject failed"

note "6. eject"
if "$APP" --eject "$BSD" >/dev/null 2>&1; then
    sleep 1
    if "$APP" --list-volumes | grep -q "^$BSD	"; then
        fail "volume still listed after eject"
    else
        pass "ejected and no longer listed"
    fi
    DEV=""
else
    fail "eject failed"
fi

note "7. diagnostics export"
DIAG="$OUT/m4-diagnostics.txt"
if "$APP" --diagnostics "$DIAG" >/dev/null 2>&1 && grep -q "detected NTFS volumes" "$DIAG"; then
    pass "diagnostics written to $DIAG"
else
    fail "diagnostics export failed"
fi

if [ "$failures" -ne 0 ]; then
    printf '\nM4 GATE: FAILED (%d failures)\n' "$failures"
    exit 1
fi
printf '\nM4 GATE: PASSED — app mount/unmount/eject verified on disposable images\n'
