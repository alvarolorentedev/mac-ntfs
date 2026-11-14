#!/bin/bash
#
# Reproducible signed build (local or CI).
#
# Signing is manual with Developer ID profiles (no device registration, no
# Xcode account). The profiles are created once via the App Store Connect API
# and then work on any machine:
#
#        export ASC_KEY_PATH=/secure/AuthKey_ABC123XYZ.p8
#        export ASC_KEY_ID=ABC123XYZ
#        export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
#        ./scripts/create-dev-id-profiles.sh   # once / when refreshing
#        ./scripts/build-signed.sh
#
# build-signed.sh runs create-dev-id-profiles.sh automatically when the ASC
# variables are set and build/profiles/ is empty.
#
# Environment:
#   PROFILE_DIR   where the .provisionprofile files live (default build/profiles)
#   CONFIG        Debug (default) or Release
#   DERIVED_DATA  derived data path (default: build/DerivedData)
#   COMPILE_ONLY  1 = unsigned compilation check (hosted CI)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
DERIVED_DATA="${DERIVED_DATA:-$REPO_ROOT/build/DerivedData}"
PROFILE_DIR="${PROFILE_DIR:-$REPO_ROOT/build/profiles}"
PROJECT="$REPO_ROOT/Mountee.xcodeproj"
SCHEME="Mountee"

if [ "${COMPILE_ONLY:-}" = "1" ]; then
    echo "==> signing mode: compile only (unsigned)"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
    exit 0
fi

if [ ! -f "$PROFILE_DIR/Mountee-App.provisionprofile" ] && \
   [ -n "${ASC_KEY_PATH:-}" ] && [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ]; then
    "$REPO_ROOT/scripts/create-dev-id-profiles.sh"
fi

if [ ! -f "$PROFILE_DIR/Mountee-App.provisionprofile" ] || \
   [ ! -f "$PROFILE_DIR/Mountee-FSKit.provisionprofile" ]; then
    echo "error: Developer ID profiles not found in $PROFILE_DIR." >&2
    echo "Set ASC_KEY_PATH + ASC_KEY_ID + ASC_ISSUER_ID and run ./scripts/create-dev-id-profiles.sh," >&2
    echo "or set COMPILE_ONLY=1 for an unsigned compilation check." >&2
    exit 1
fi

echo "==> signing mode: manual Developer ID"
echo "    profiles: $PROFILE_DIR"

# Make the profiles visible to xcodebuild's manual signing lookup.
for directory in \
    "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    mkdir -p "$directory"
    cp -f "$PROFILE_DIR"/*.provisionprofile "$directory/"
done

# A notarized/stapled Release app carries com.apple.provenance xattrs and can
# no longer be modified in place (Xcode fails writing the embedded profile
# with EPERM). Remove the product so the build writes it fresh.
if [ "$CONFIG" = "Release" ]; then
    APP_PRODUCT="$DERIVED_DATA/Build/Products/Release/Mountee.app"
    case "$APP_PRODUCT" in
        */Build/Products/Release/Mountee.app)
            rm -rf "$APP_PRODUCT"
            ;;
    esac
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" build

APP="$DERIVED_DATA/Build/Products/$CONFIG/Mountee.app"
APPEX="$APP/Contents/Extensions/MounteeFSKit.appex"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION="$SPARKLE/Versions/B"

# Xcode signs Sparkle's framework root but leaves its nested helpers unsigned.
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$SPARKLE_VERSION/Autoupdate"
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$SPARKLE_VERSION/Updater.app"
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --preserve-metadata=identifier,entitlements,flags,requirements "$SPARKLE"
codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --preserve-metadata=identifier,entitlements,flags,requirements "$APP"

echo
echo "==> artifacts"
echo "    $APP"

echo "==> signature check"
codesign --verify --deep --strict "$APP"
APPEX_ENTITLEMENTS="$(codesign -d --entitlements - "$APPEX" 2>/dev/null || true)"
APP_ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
if ! grep -q "com.apple.developer.fskit.fsmodule" <<<"$APPEX_ENTITLEMENTS"; then
    echo "error: appex is missing com.apple.developer.fskit.fsmodule" >&2
    exit 1
fi
if ! grep -q "com.apple.developer.fskit.mount" <<<"$APP_ENTITLEMENTS"; then
    echo "error: app is missing com.apple.developer.fskit.mount" >&2
    exit 1
fi
echo "    entitlements OK"
