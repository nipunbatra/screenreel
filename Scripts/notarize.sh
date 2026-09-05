#!/bin/bash
# Notarize and staple a signed DMG, then verify Gatekeeper accepts it.
#
# Usage: Scripts/notarize.sh [dist/<APP_NAME>-<VERSION>.dmg]
#
# One-time setup (docs/DISTRIBUTION.md):
#   xcrun notarytool store-credentials screenreel-notary \
#       --apple-id <apple-id-email> --team-id <TEAMID> --password <app-specific-password>
# The profile name below must match. Every step fails loudly; nothing here
# retries silently or falls back to an unnotarized artifact.
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="${APP_NAME:-Screenreel}"
VERSION="$(tr -d '[:space:]' < VERSION)"
PROFILE="${NOTARY_PROFILE:-screenreel-notary}"
DMG="${1:-dist/${APP_NAME}-${VERSION}.dmg}"

[ -f "$DMG" ] || { echo "ERROR: $DMG not found — run Scripts/make-dmg.sh first" >&2; exit 1; }
case "$DMG" in
    *-unsigned.dmg) echo "ERROR: $DMG is an ad-hoc test build and cannot be notarized" >&2; exit 1 ;;
esac
xcrun --find notarytool >/dev/null 2>&1 || { echo "ERROR: notarytool not found; install Xcode 13+ command line tools" >&2; exit 1; }
xcrun --find stapler >/dev/null 2>&1 || { echo "ERROR: stapler not found" >&2; exit 1; }

# Refuse early if the DMG is not Developer ID signed — Apple would reject it
# after a long upload anyway.
if ! codesign --verify --verbose=2 "$DMG" 2>&1 | grep -q "valid on disk"; then
    echo "ERROR: $DMG is not validly signed; rebuild with Scripts/make-dmg.sh" >&2
    exit 1
fi
if ! codesign -dvv "$DMG" 2>&1 | grep -q "Authority=Developer ID Application"; then
    echo "ERROR: $DMG is not signed with a Developer ID Application certificate" >&2
    exit 1
fi

# Confirm the keychain profile exists before uploading anything.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<MSG
ERROR: notarytool keychain profile '$PROFILE' is missing or the keychain is locked.
  Create it once with:
    xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id <TEAMID> --password <app-specific-password>
  (app-specific password: https://account.apple.com → Sign-In and Security → App-Specific Passwords)
  If it exists, unlock the keychain: security unlock-keychain ~/Library/Keychains/login.keychain-db
MSG
    exit 1
fi

echo "Submitting $DMG for notarization (profile: $PROFILE)…"
LOG="$(mktemp -t notarize).json"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$LOG"; then
    echo "ERROR: notarytool submit failed; output:" >&2
    cat "$LOG" >&2
    exit 1
fi
STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$LOG")
SUBMISSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$LOG")
echo "Submission $SUBMISSION: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
    echo "ERROR: notarization was not accepted. Full log:" >&2
    xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2 || true
    exit 1
fi

echo "Stapling ticket…"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "Gatekeeper assessment…"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Also assess the app inside the image, exactly as a user would receive it.
MOUNT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT" -nobrowse -quiet
trap 'hdiutil detach "$MOUNT" -quiet || true' EXIT
spctl --assess --type execute --verbose=2 "$MOUNT/${APP_NAME}.app"
codesign --verify --deep --strict --verbose=2 "$MOUNT/${APP_NAME}.app"
hdiutil detach "$MOUNT" -quiet
trap - EXIT

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Notarized and stapled: $DMG"
echo "Next: Scripts/release.sh"
