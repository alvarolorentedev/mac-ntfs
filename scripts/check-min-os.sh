#!/bin/bash
#
# Verifies every Mach-O in the built app is stamped for the deployment floor
# (defaults to the project's MACOSX_DEPLOYMENT_TARGET, currently 26.0). The
# deployment target is what makes the compiler reject any accidental use of
# newer APIs, so this is the "can we still compile for the floor" check; pair
# it with scripts/vm-validate.sh for the runtime check.
#
# Usage: scripts/check-min-os.sh [floor]
#   floor defaults to the project's MACOSX_DEPLOYMENT_TARGET.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PBXPROJ="$REPO_ROOT/MacNTFS.xcodeproj/project.pbxproj"
CONFIG="${CONFIG:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build/DerivedData}"
APP="$DERIVED_DATA/Build/Products/$CONFIG/MacNTFS.app"

FLOOR="${1:-}"
if [ -z "$FLOOR" ]; then
    FLOOR="$(awk -F' = ' '/MACOSX_DEPLOYMENT_TARGET = /{print $2}' "$PBXPROJ" | tr -d ';' | sort -u | head -1)"
fi
if [ -z "$FLOOR" ]; then
    echo "error: no MACOSX_DEPLOYMENT_TARGET found in project" >&2
    exit 1
fi
if [ ! -d "$APP" ]; then
    echo "error: $APP not built. Run scripts/build-signed.sh first." >&2
    exit 1
fi

# Numeric, segment-wise compare: floor_ok("26.0", "26.0") == 0, ("27.0", "26.0") == 1.
floor_ok() {
    awk -v have="$1" -v floor="$2" 'BEGIN {
        na = split(have, a, "."); nb = split(floor, b, ".")
        for (i = 1; i <= 3; i++) {
            av = (i <= na) ? a[i] + 0 : 0
            bv = (i <= nb) ? b[i] + 0 : 0
            if (av > bv) exit 1
            if (av < bv) exit 0
        }
        exit 0
    }'
}

failures=0
printf 'deployment floor: macOS %s\n\n' "$FLOOR"
printf '%-9s %s\n' "minos" "binary"
while IFS= read -r file; do
    minos="$(otool -l "$file" 2>/dev/null | awk '/LC_BUILD_VERSION/{found=1} found && /minos/{print $2; exit}')"
    [ -z "$minos" ] && continue
    rel="${file#"$APP"/}"
    printf '%-9s %s\n' "$minos" "$rel"
    if ! floor_ok "$minos" "$FLOOR"; then
        echo "  ^ error: newer than the floor; the compiler gate is not in effect for this file" >&2
        failures=$((failures + 1))
    fi
done < <(find "$APP" -type f \( -perm -u+x -o -name "*.dylib" \) | sort)

if [ "$failures" -ne 0 ]; then
    printf '\nMIN-OS CHECK: FAILED (%d file(s) above %s)\n' "$failures" "$FLOOR"
    exit 1
fi
printf '\nMIN-OS CHECK: PASSED\n'
