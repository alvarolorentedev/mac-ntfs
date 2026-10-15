#!/bin/bash
#
# Builds the distributable installer: a signed, notarized, stapled DMG.
#
# Prerequisites:
#   CONFIG=Release ./scripts/build-signed.sh   (a Developer ID signed app)
#   ASC_KEY_PATH / ASC_KEY_ID / ASC_ISSUER_ID  (for notarization; optional)
#
# Environment:
#   CONFIG     Debug or Release (default Release)
#   APP        override the app path
#   OUT_DIR    where the DMG is written (default build/installer)
#   NOTARIZE   auto (default), 1, or 0
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
APP="${APP:-$REPO_ROOT/build/DerivedData/Build/Products/$CONFIG/MacNTFS.app}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/build/installer}"
NOTARIZE="${NOTARIZE:-auto}"

if [ ! -d "$APP" ]; then
    echo "error: $APP not found. Run: CONFIG=$CONFIG ./scripts/build-signed.sh" >&2
    exit 1
fi

echo "==> verifying signature"
codesign --verify --strict "$APP"
SIGNATURE_INFO="$(codesign -dv --verbose=2 "$APP" 2>&1 || true)"
if ! grep -q "Authority=Developer ID Application" <<<"$SIGNATURE_INFO"; then
    echo "error: app is not Developer ID signed; refusing to package for distribution" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
mkdir -p "$OUT_DIR"
DMG="$OUT_DIR/MacNTFS-$VERSION.dmg"

notarize=0
case "$NOTARIZE" in
    1|yes|true) notarize=1 ;;
    auto)
        if [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
            notarize=1
        fi
        ;;
esac

notarytool_submit() {
    local artifact="$1"
    local log
    log="$(mktemp)"
    echo "==> notarizing $(basename "$artifact") (this can take several minutes)"
    if ! xcrun notarytool submit "$artifact" \
        --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        --wait 2>&1 | tee "$log"; then
        rm -f "$log"
        echo "error: notarization submission failed" >&2
        return 1
    fi
    if grep -q "status: Invalid" "$log"; then
        local submission_id
        submission_id="$(grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$log" | head -1)"
        cat "$log" >&2
        rm -f "$log"
        echo "error: notarization rejected; log follows" >&2
        if [ -n "$submission_id" ]; then
            xcrun notarytool log "$submission_id" \
                --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" || true
        fi
        return 1
    fi
    rm -f "$log"
}

if [ "$notarize" = 1 ]; then
    ZIP="$OUT_DIR/MacNTFS-$VERSION.zip"
    rm -f "$ZIP"
    echo "==> packaging app for notarization"
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarytool_submit "$ZIP"
    rm -f "$ZIP"
    echo "==> stapling the app"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
else
    echo "==> notarization skipped (set ASC_KEY_PATH/ASC_KEY_ID/ASC_ISSUER_ID and NOTARIZE=1 to enable)"
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
echo "==> staging"
cp -R "$APP" "$STAGE/MacNTFS.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<TXT
MacNTFS $VERSION

1. Drag MacNTFS.app to the Applications folder.
2. Launch it and press "Enable File System Extension" (menu bar -> drive icon).
3. Plug in an NTFS disk. It appears in /Volumes and in the MacNTFS menu,
   mounted read-only until you explicitly choose "Mount Read/Write".

Safety: dirty volumes and volumes hibernated by Windows (Fast Startup) are
always mounted read-only. MacNTFS never formats or repairs disks.

Source and documentation: https://github.com/alvarolorentedev/mac-ntfs
TXT

echo "==> creating DMG"
rm -f "$DMG"
hdiutil create -quiet -volname "MacNTFS" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "==> signing the DMG"
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

if [ "$notarize" = 1 ]; then
    notarytool_submit "$DMG"
    echo "==> stapling the DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 || true
fi

echo
echo "==> installer ready"
echo "    $DMG"
shasum -a 256 "$DMG"
