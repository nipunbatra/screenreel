#!/bin/bash
# Build a distributable, Developer ID-signed DMG:
#   Scripts/make-app.sh (strict signing) → dist/<APP_NAME>-<VERSION>.dmg (signed)
#
# Usage: Scripts/make-dmg.sh
#   ALLOW_ADHOC=1  build an UNSIGNED/ad-hoc DMG for local testing only. It
#                  cannot be notarized and Gatekeeper will refuse it on other
#                  Macs; the file name is marked "-unsigned" so it cannot be
#                  released by mistake.
#
# Requires: Xcode command line tools, a "Developer ID Application" identity
# in an UNLOCKED login keychain (see docs/DISTRIBUTION.md).
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="${APP_NAME:-Screen Reel}"
ARTIFACT_NAME="${ARTIFACT_NAME:-screenreel}"
VERSION="$(tr -d '[:space:]' < VERSION)"
OUT="dist"
STAGING="$OUT/dmg-staging"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"

command -v hdiutil >/dev/null || { echo "hdiutil not found" >&2; exit 1; }
command -v codesign >/dev/null || { echo "codesign not found (install Xcode command line tools)" >&2; exit 1; }

if [ "$ALLOW_ADHOC" = "1" ]; then
    echo "ALLOW_ADHOC=1: building an unsigned test DMG (not releasable)"
    DMG="$OUT/${ARTIFACT_NAME}-${VERSION}-unsigned.dmg"
    ALLOW_ADHOC=1 Scripts/make-app.sh "$OUT"
else
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
    if [ -z "$IDENTITY" ]; then
        cat >&2 <<'MSG'
ERROR: no "Developer ID Application" identity found.
  - Create one at https://developer.apple.com/account/resources/certificates (Developer ID Application),
    install it in the login keychain, and confirm with:  security find-identity -v -p codesigning
  - If the identity exists but signing fails with errSecInternalComponent, the keychain is locked
    (typical over SSH or in an agent session):  security unlock-keychain ~/Library/Keychains/login.keychain-db
  - For a local, non-releasable test build:  ALLOW_ADHOC=1 Scripts/make-dmg.sh
MSG
        exit 1
    fi
    DMG="$OUT/${ARTIFACT_NAME}-${VERSION}.dmg"
    REQUIRE_DEVELOPER_ID=1 Scripts/make-app.sh "$OUT"
fi

APP="$OUT/${APP_NAME}.app"
[ -d "$APP" ] || { echo "make-app.sh did not produce $APP" >&2; exit 1; }

# Stage: the app plus an /Applications symlink so the DMG is drag-to-install.
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# APFS is supported on every target Mac. The HFS+ image builder on the
# release host produced invalid BLKX offsets despite exiting successfully.
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO -fs APFS "$DMG" >/dev/null
hdiutil verify "$DMG"
rm -rf "$STAGING"

if [ "$ALLOW_ADHOC" != "1" ]; then
    # The DMG itself is signed so Gatekeeper can attribute it; the ticket
    # from notarize.sh is later stapled to this same file.
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    codesign --verify --verbose=2 "$DMG"
fi
hdiutil verify "$DMG"

(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")") | tee "$DMG.sha256"
echo "Built $DMG"
if [ "$ALLOW_ADHOC" != "1" ]; then
    echo "Next: Scripts/notarize.sh $DMG"
fi
