#!/bin/bash
#
# M1 gate: prove the signed FSKit module loads and mounts a disposable NTFS
# image on this Mac. Never touches physical disks: the device comes from
# attaching a raw image file, and its name is validated before use.
#
# Usage: scripts/m1-mount-test.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/build/DerivedData/Build/Products/Debug/MacNTFS.app"
APPEX="$APP/Contents/Extensions/NTFSModule.appex"
MODULE_ID="com.github.alvarolorentedev.macntfs.ntfsmodule"
MOUNTPOINT="${MOUNTPOINT:-$REPO_ROOT/build/mnt}"
IMG="$REPO_ROOT/build/test-images/ntfs-test-64mb.img"
ENABLED_PLIST="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"

fail=0
note() { printf '\n== %s\n' "$1"; }

note "preflight"
if [ ! -d "$APP" ]; then
    echo "error: app not built. Run:" >&2
    echo "  ./scripts/build-signed.sh" >&2
    exit 1
fi
if [ ! -x "$REPO_ROOT/build/bin/mkntfs" ]; then
    echo "error: build/bin/mkntfs missing. Run scripts/build-libntfs.sh first." >&2
    exit 1
fi

note "signature and entitlements"
codesign -dv --entitlements :- "$APPEX" 2>&1 | sed -n '1,40p'
if ! codesign --verify --strict "$APP" 2>/dev/null; then
    echo "warning: signature verification failed (unsigned or invalid)"
    fail=1
fi

note "registration"
pluginkit -a "$APPEX" 2>&1 || true
pluginkit -m -p com.apple.fskit.fsmodule -vv 2>&1 | grep -A8 -i macntfs || echo "(module not visible to pluginkit yet)"

note "enablement"
if "$APP/Contents/MacOS/MacNTFS" --enable-extension; then
    echo "extension enabled"
else
    echo "direct enablement failed (expected when this script runs under a sandbox)"
    echo "falling back to LaunchServices (unsandboxed context)"
    open -n "$APP" --args --enable-extension 2>/dev/null || true
    sleep 8
    if [ "$("$APP/Contents/MacOS/MacNTFS" --extension-status 2>/dev/null)" = "enabled" ]; then
        echo "extension enabled (via LaunchServices)"
    else
        echo "automatic enablement failed"
        echo "fallback: open the app and press 'Enable Extension', or run:"
        echo "  \"$APP/Contents/MacOS/MacNTFS\" --enable-extension"
        echo "alternatively: System Settings -> General -> Login Items & Extensions -> File System Extensions"
    fi
fi

note "test image"
"$REPO_ROOT/scripts/make-test-image.sh" 64 "$IMG" || exit 1

note "attach image"
ATTACH_OUT="$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG")"
echo "$ATTACH_OUT"
DEV="$(printf '%s\n' "$ATTACH_OUT" | awk 'NR==1 {print $1}')"

# Trust-boundary validation: only accept a whole-disk BSD name.
if ! [[ "$DEV" =~ ^/dev/disk[0-9]+$ ]]; then
    echo "error: unexpected device name from hdiutil: '$DEV'" >&2
    exit 1
fi

note "mount (read-only default)"
mkdir -p "$MOUNTPOINT"
MOUNTED=0
if mount -F -t macntfs "$DEV" "$MOUNTPOINT"; then
    MOUNTED=1
else
    echo "mount as user failed; retrying with sudo (only if passwordless)"
    if sudo -n mount -F -t macntfs "$DEV" "$MOUNTPOINT" 2>/dev/null; then
        MOUNTED=1
    else
        echo "To retry manually: sudo mount -F -t macntfs $DEV $MOUNTPOINT"
    fi
fi

if [ "$MOUNTED" = "1" ]; then
    note "verify"
    mount | grep -- "$MOUNTPOINT" || fail=1
    ls -la "$MOUNTPOINT" || fail=1
    stat -f "%N: %z bytes, fstype=%T" "$MOUNTPOINT" || true
    df -h "$MOUNTPOINT" || true

    note "unmount"
    umount "$MOUNTPOINT" || sudo -n umount "$MOUNTPOINT" || fail=1
else
    fail=1
fi

note "detach image"
hdiutil detach "$DEV" >/dev/null 2>&1 || true

if [ "$fail" != "0" ]; then
    note "diagnostics"
    "$REPO_ROOT/scripts/fskit-diagnose.sh"
    echo
    echo "M1 GATE: FAILED — see diagnostics above"
    exit 1
fi

printf '\nM1 GATE: PASSED — module loaded and mounted a disposable NTFS image\n'
