#!/bin/bash
#
# Collects FSKit/extension signing, registration and mount diagnostics into
# build/diagnostics/<timestamp>/. Read-only: runs no mounts and writes nothing
# outside the repo.
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO_ROOT/build/diagnostics/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

MODULE_ID="com.github.alvarolorentedev.macntfs.ntfsmodule"
ENABLED_PLIST="$HOME/Library/Group Containers/group.com.apple.fskit.settings/enabledModules.plist"

section() { printf '\n===== %s =====\n' "$1"; }

{
    echo "host: macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
    echo "date: $(date)"

    section "System Integrity Protection"
    csrutil status 2>&1

    section "code signing identities"
    security find-identity -v -p codesigning 2>&1

    section "registered FSKit modules (all)"
    pluginkit -m -p com.apple.fskit.fsmodule -vv 2>&1

    section "registered FSKit modules (macntfs only)"
    pluginkit -m -p com.apple.fskit.fsmodule -vv 2>&1 | grep -B1 -A8 -i macntfs || echo "(not registered)"

    section "system extensions"
    systemextensionsctl list 2>&1

    section "FSKit enabled modules (per-user)"
    if [ -f "$ENABLED_PLIST" ]; then
        plutil -p "$ENABLED_PLIST" 2>&1
    else
        echo "(no enabledModules.plist)"
    fi

    section "fskitd"
    pgrep -lf fskitd || echo "(fskitd not running)"

    section "fskit_agent"
    pgrep -lf fskit_agent || echo "(fskit_agent not running)"

    section "current mounts (ntfs/fskit)"
    mount 2>&1 | grep -i -E "ntfs|fskit" || echo "(none)"
} > "$OUT/state.txt" 2>&1

log show --last 15m --style compact --info \
    --predicate 'subsystem == "com.apple.FSKit" OR process == "fskitd" OR process CONTAINS "NTFSModule"' \
    > "$OUT/fskit.log" 2>&1 || true

echo "diagnostics written to $OUT"
