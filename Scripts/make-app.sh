#!/bin/bash
# Assemble Aks.app from the SwiftPM release build.
# Usage: Scripts/make-app.sh [output-dir]   (default: ./dist)
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-dist}"
# Display name is rebrandable (APP_NAME="Drishya" Scripts/make-app.sh);
# bundle id and project format identifiers stay stable on purpose.
APP_NAME="${APP_NAME:-Screenreel}"
# The single source of truth for the version is the VERSION file; it becomes
# CFBundleShortVersionString and CFBundleVersion, and release.sh tags v$VERSION.
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] \
    || { echo "VERSION file must contain MAJOR.MINOR.PATCH, got '$VERSION'" >&2; exit 1; }
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# REQUIRE_DEVELOPER_ID=1 (set by make-dmg.sh) turns the ad-hoc fallback into
# a hard failure: a distributable build must be Developer ID signed with the
# hardened runtime and a secure timestamp, or notarization is pointless.
# ALLOW_ADHOC=1 does the opposite: skip identities entirely and sign ad-hoc
# (useful when the keychain is locked, e.g. over SSH; TCC grants reset).
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"
ALLOW_ADHOC="${ALLOW_ADHOC:-0}"
if [ "$REQUIRE_DEVELOPER_ID" = "1" ] && [ "$ALLOW_ADHOC" = "1" ]; then
    echo "REQUIRE_DEVELOPER_ID=1 and ALLOW_ADHOC=1 contradict each other" >&2; exit 1
fi
swift build -c release --product AksApp

APP="$OUT/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AksApp "$APP/Contents/MacOS/${APP_NAME}"

# App icon: generated original artwork, cached across builds.
ICON_CACHE=".build/AppIcon.icns"
if [ ! -f "$ICON_CACHE" ] || [ "Scripts/make-icon.swift" -nt "$ICON_CACHE" ]; then
    swift Scripts/make-icon.swift "$ICON_CACHE"
fi
mkdir -p "$APP/Contents/Resources"
cp "$ICON_CACHE" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>APP_NAME_PLACEHOLDER</string>
    <key>CFBundleIdentifier</key><string>in.aks.app</string>
    <key>CFBundleName</key><string>APP_NAME_PLACEHOLDER</string>
    <key>CFBundleDisplayName</key><string>APP_NAME_PLACEHOLDER</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>VERSION_PLACEHOLDER</string>
    <key>CFBundleVersion</key><string>VERSION_PLACEHOLDER</string>
    <key>SRBuildDate</key><string>BUILD_DATE_PLACEHOLDER</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Records your microphone as a separate raw track alongside the screen.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Transcribes your narration on-device to generate captions (SRT/VTT). Audio never leaves this Mac.</string>
    <key>NSCameraUsageDescription</key>
    <string>Records your camera as a separate raw track for picture-in-picture layouts.</string>
    <key>NSHumanReadableCopyright</key><string>Open source. No telemetry.</string>
</dict>
</plist>
PLIST
sed -i '' -e "s/APP_NAME_PLACEHOLDER/${APP_NAME}/g" \
    -e "s/VERSION_PLACEHOLDER/${VERSION}/g" \
    -e "s/BUILD_DATE_PLACEHOLDER/${BUILD_DATE}/g" "$APP/Contents/Info.plist"

# Hardened runtime blocks camera and microphone outright unless the binary
# declares the matching entitlements — macOS then reports "denied" without
# ever showing a prompt, and no Settings toggle can fix it.
ENTITLEMENTS="$APP/../.entitlements.plist"
cat > "$ENTITLEMENTS" <<'EPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key><true/>
    <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
EPLIST

# Sign with a stable identity so TCC grants survive rebuilds. Ad-hoc
# signatures change every build, which silently invalidates Screen
# Recording/Microphone grants while System Settings still shows them ON.
IDENTITY=""
if [ "$ALLOW_ADHOC" != "1" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
fi
if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
    if [ -z "$IDENTITY" ]; then
        echo "ERROR: REQUIRE_DEVELOPER_ID=1 but no 'Developer ID Application' identity is available." >&2
        echo "       Install the certificate and unlock the login keychain (docs/DISTRIBUTION.md)." >&2
        exit 1
    fi
    echo "Signing for distribution with: $IDENTITY"
    # No fallback here on purpose: hardened runtime + secure timestamp are
    # required for notarization. errSecInternalComponent means the keychain
    # is locked (common over SSH): security unlock-keychain ~/Library/Keychains/login.keychain-db
    codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" \
        --sign "$IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    if [ -z "$IDENTITY" ] && [ "$ALLOW_ADHOC" != "1" ]; then
        IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
            | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
    fi
    if [ -n "$IDENTITY" ]; then
        echo "Signing with: $IDENTITY"
        codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" \
            --sign "$IDENTITY" "$APP" 2>/dev/null \
            || codesign --force --deep --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
    else
        [ "$ALLOW_ADHOC" = "1" ] && echo "ALLOW_ADHOC=1: signing ad-hoc (permissions reset every rebuild)" \
            || echo "No signing identity found; using ad-hoc (permissions reset every rebuild)"
        codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$APP"
    fi
fi
rm -f "$ENTITLEMENTS"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "device.camera" \
    && echo "Entitlements verified: camera + audio-input" \
    || echo "WARNING: entitlements missing from signature"
echo "Built $APP ($VERSION, $BUILD_DATE)"
echo "First launch: grant Screen Recording + Microphone + Input Monitoring in System Settings when prompted."
