#!/bin/bash
#
# Runs the full disposable-image validation: engine tests, M3 mounted
# read/write gate, M4 app code paths. Never touches physical disks.
#
# Usage: scripts/validate-all.sh [--with-m1]
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WITH_M1=0
if [ "${1:-}" = "--with-m1" ]; then
    WITH_M1=1
fi

failures=0
run_step() {
    local name="$1"
    shift
    printf '\n########## %s ##########\n' "$name"
    if "$@"; then
        printf '>>> %s: PASSED\n' "$name"
    else
        printf '>>> %s: FAILED\n' "$name"
        failures=$((failures + 1))
    fi
}

run_step "min-OS floor check" "$REPO_ROOT/scripts/check-min-os.sh"
run_step "engine tests" "$REPO_ROOT/scripts/run-engine-tests.sh"
run_step "M3 mounted read/write gate" "$REPO_ROOT/scripts/m3-mount-test.sh"
run_step "M4 app mount/unmount/eject gate" "$REPO_ROOT/scripts/m4-mount-test.sh"
if [ "$WITH_M1" = "1" ]; then
    run_step "M1 mount gate" "$REPO_ROOT/scripts/m1-mount-test.sh"
fi

if [ "$failures" -ne 0 ]; then
    printf '\nVALIDATION: FAILED (%d step(s))\n' "$failures"
    exit 1
fi
printf '\nVALIDATION: PASSED\n'
