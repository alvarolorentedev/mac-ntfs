#!/bin/bash
#
# Creates/refreshes the Developer ID provisioning profiles for both App IDs
# via the App Store Connect API and writes them to build/profiles/.
#
# Requires: ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID (see docs/DEVELOPMENT.md).
# Developer ID profiles need no device registration and work on any machine,
# which is what makes CI reproducible.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for variable in ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID; do
    if [ -z "${!variable:-}" ]; then
        echo "error: $variable is not set (see docs/DEVELOPMENT.md, 'Signing')" >&2
        exit 1
    fi
done

export PROFILE_DIR="${PROFILE_DIR:-$REPO_ROOT/build/profiles}"
swift "$REPO_ROOT/scripts/asc-profiles.swift"
