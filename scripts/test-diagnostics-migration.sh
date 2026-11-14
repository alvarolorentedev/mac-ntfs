#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$(mktemp "${TMPDIR:-/tmp}/mountee-diagnostics-migration.XXXXXX")"
trap 'rm -f "$BINARY"' EXIT

swiftc -parse-as-library -framework AppKit \
    "$REPO_ROOT/Mountee/Diagnostics.swift" \
    "$REPO_ROOT/tests/diagnostics-migration.swift" \
    -o "$BINARY"
"$BINARY"
