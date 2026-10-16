#!/bin/bash
#
# Validates the current signed build against a macOS version in a disposable
# Tart VM: copies the app in, enables the extension, runs the engine, M3 and
# M4 gates, and reports which FSKit volume adapter served the mount.
#
# Usage: scripts/vm-validate.sh <tart-image-ref> [vm-name] [--keep]
#
#   scripts/vm-validate.sh ghcr.io/cirruslabs/macos-tahoe-base:latest
#   scripts/vm-validate.sh ghcr.io/cirruslabs/macos-sequoia-base:latest mac15 --keep
#
# The registry only publishes "latest" per OS family, so this validates the
# newest point release of a line (e.g. 26.7). For an exact older build, create
# a VM from an .ipsw (`tart create --from-ipsw`) and install the Tart guest
# agent (https://github.com/cirruslabs/tart-guest-agent) so `tart exec` works,
# then pass its name here.
#
# Requires: tart, a signed build in build/DerivedData (scripts/build-signed.sh)
# and prebuilt engine tests (scripts/run-engine-tests.sh).
#
# The supported floor is macOS 26; macOS 15.x is unsupported (the 15.x system
# mount paths fail even for Apple's own FSKit module — see docs/VALIDATION.md).
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${1:-}"
VM="${2:-}"
KEEP=0
[ "${3:-}" = "--keep" ] && KEEP=1
[ "${2:-}" = "--keep" ] && { KEEP=1; VM=""; }
[ -z "$VM" ] && VM="macntfs-validate-$(date +%s)"

APP_HOST="$REPO_ROOT/build/DerivedData/Build/Products/Debug/MacNTFS.app"
ENGINE_HOST="$REPO_ROOT/build/tests/engine_tests"
MODULE_ID="com.github.alvarolorentedev.macntfs.ntfsmodule"
GUEST_TMP="/tmp/macntfs-validate"
GUEST_MNT='$HOME/macntfs-validate-mnt'

step() { printf '\n== %s\n' "$1"; }
failures=0
created=0

if [ -z "$IMAGE" ]; then
    echo "usage: $0 <tart-image-ref> [vm-name] [--keep]" >&2
    exit 2
fi
command -v tart >/dev/null 2>&1 || { echo "error: tart is not installed" >&2; exit 2; }
[ -d "$APP_HOST" ] || { echo "error: app not built. Run scripts/build-signed.sh" >&2; exit 2; }
[ -x "$ENGINE_HOST" ] || { echo "error: engine tests missing. Run scripts/run-engine-tests.sh" >&2; exit 2; }

gex() { tart exec "$VM" bash -lc "$1"; }

# --- VM lifecycle -----------------------------------------------------------

if tart exec "$VM" true >/dev/null 2>&1; then
    step "reusing running VM '$VM'"
else
    if tart list 2>/dev/null | awk -v n="$VM" '$1=="local" && $2==n {found=1} END{exit !found}'; then
        step "starting existing VM '$VM'"
    else
        step "cloning '$IMAGE' -> '$VM'"
        tart clone "$IMAGE" "$VM" || exit 1
        created=1
    fi
    nohup tart run "$VM" --no-graphics --dir="macntfs:$REPO_ROOT" \
        >"/tmp/tart-$VM.log" 2>&1 &
    for _ in $(seq 1 60); do
        tart exec "$VM" true >/dev/null 2>&1 && break
        sleep 5
    done
    if ! tart exec "$VM" true >/dev/null 2>&1; then
        echo "error: VM '$VM' did not come up; see /tmp/tart-$VM.log" >&2
        exit 1
    fi
fi

cleanup() {
    if [ "$KEEP" = "1" ]; then
        printf '\nkept VM %s (tart stop %s / tart delete %s)\n' "$VM" "$VM" "$VM"
    elif [ "$created" = "1" ]; then
        tart stop "$VM" >/dev/null 2>&1
        tart delete "$VM" >/dev/null 2>&1
        printf '\ndeleted VM %s\n' "$VM"
    else
        printf '\nleft pre-existing VM %s running\n' "$VM"
    fi
}
trap cleanup EXIT

OS_VERSION="$(gex 'sw_vers -productVersion')"
OS_BUILD="$(gex 'sw_vers -buildVersion')"
printf 'guest: macOS %s (%s)\n' "$OS_VERSION" "$OS_BUILD"

# --- Shared folder and sudo -------------------------------------------------

SHARE="$(gex 'ls -d "/Volumes/My Shared Files"/*/MacNTFS.xcodeproj 2>/dev/null | head -1' | sed 's|/MacNTFS.xcodeproj$||')"
if [ -z "$SHARE" ]; then
    echo "error: repo share not found in the guest; start the VM with --dir=macntfs:$REPO_ROOT" >&2
    exit 1
fi
printf 'share: %s\n' "$SHARE"

if ! tart exec "$VM" sudo -n true >/dev/null 2>&1; then
    gex 'echo admin | sudo -S sh -c "echo \"admin ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/admin && chmod 440 /etc/sudoers.d/admin"' >/dev/null 2>&1 || true
fi

# --- Install, register, enable ----------------------------------------------

step "installing and enabling the extension"
gex "sudo rm -rf /Applications/MacNTFS.app && sudo ditto \"$SHARE/build/DerivedData/Build/Products/Debug/MacNTFS.app\" /Applications/MacNTFS.app && codesign --verify --strict /Applications/MacNTFS.app" \
    || { echo "error: app install/codesign failed" >&2; exit 1; }
gex 'open /Applications/MacNTFS.app; sleep 6; pkill -x MacNTFS; true'
gex '/Applications/MacNTFS.app/Contents/MacOS/MacNTFS --enable-extension' || true
# On 26, the FSKit enabled-list plist is authoritative; pluginkit is kept as a
# belt-and-braces fallback.
gex "pluginkit -e use -i $MODULE_ID >/dev/null 2>&1; true"
gex 'sudo killall -9 fskitd fskit_agent 2>/dev/null; true'
sleep 2
STATUS="$(gex '/Applications/MacNTFS.app/Contents/MacOS/MacNTFS --extension-status 2>&1')"
printf 'extension status: %s\n' "$STATUS"

# --- Engine tests ------------------------------------------------------------

step "engine tests (guest)"
gex "mkdir -p $GUEST_TMP"
for image in cycle dirty hibernated extra; do
    gex "\"$SHARE/scripts/make-test-image.sh\" 64 $GUEST_TMP/engine-$image.img >/dev/null" \
        || { echo "error: could not create $image image" >&2; exit 1; }
done
ENGINE_OUT="$(gex "\"$SHARE/build/tests/engine_tests\" $GUEST_TMP/engine-cycle.img $GUEST_TMP/engine-dirty.img $GUEST_TMP/engine-hibernated.img $GUEST_TMP/engine-extra.img" 2>&1)"
echo "$ENGINE_OUT" | tail -2
echo "$ENGINE_OUT" | grep -q "ENGINE TESTS: PASSED" || failures=$((failures + 1))

# --- M3 and M4 gates ---------------------------------------------------------

step "M3 gate (guest)"
M3_OUT="$(gex "cd \"$SHARE\" && MOUNTPOINT=$GUEST_MNT ./scripts/m3-mount-test.sh 2>&1")"
echo "$M3_OUT" | tail -6
echo "$M3_OUT" | grep -q "M3 GATE: PASSED" || failures=$((failures + 1))

step "M4 gate (guest)"
M4_OUT="$(gex "cd \"$SHARE\" && ./scripts/m4-mount-test.sh 2>&1")"
echo "$M4_OUT" | tail -6
echo "$M4_OUT" | grep -q "M4 GATE: PASSED" || failures=$((failures + 1))

# --- Evidence ----------------------------------------------------------------

step "volume adapter actually used"
gex 'log show --last 45m --predicate "process == \"NTFSModule\"" --style compact 2>/dev/null | grep -c "using the legacy FSVolume.Operations adapter" || true' \
    | sed 's/^/V1 (FSVolume.Operations) loads: /'
gex 'log show --last 45m --predicate "process == \"NTFSModule\"" --style compact 2>/dev/null | grep -c "using the macOS 27+ FSVolume.Handler adapter" || true' \
    | sed 's/^/V3 (FSVolume.Handler) loads:    /'

if [ "$failures" -ne 0 ]; then
    printf '\nVM VALIDATION (macOS %s): FAILED (%d gate(s))\n' "$OS_VERSION" "$failures"
    exit 1
fi
printf '\nVM VALIDATION (macOS %s): PASSED\n' "$OS_VERSION"
