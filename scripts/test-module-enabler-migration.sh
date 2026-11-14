#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$(mktemp "${TMPDIR:-/tmp}/mountee-module-migration.XXXXXX")"
trap 'rm -f "$BINARY"' EXIT

swiftc -parse-as-library -framework FSKit \
    "$REPO_ROOT/Mountee/ModuleEnabler.swift" \
    "$REPO_ROOT/Mountee/FSKitDaemonEnablement.swift" \
    "$REPO_ROOT/tests/module-enabler-migration.swift" \
    -o "$BINARY"
"$BINARY"
