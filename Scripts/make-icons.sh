#!/bin/bash
# Regenerate every raster brand asset from the SVG sources in Assets/.
# Deterministic: same sources + same macOS version => byte-identical output.
# Needs only macOS (AppKit via `swift`, `iconutil`); no Homebrew tools.
#
#   Scripts/make-icons.sh            # rebuild everything into Assets/ and website/assets/
#   Scripts/make-icons.sh out.icns   # only build the .icns to the given path
#
# Sources (edit these, then re-run; see docs/BRAND.md):
#   Assets/AppIcon.svg          app icon, 1024 canvas, Apple's 824 px stage
#   Assets/AppIcon-small.svg    16/32 px variant (no outer shadow)
#   Assets/MenuBarIcon.svg      18 pt monochrome menu-bar mark (template)
#   Assets/brand/wordmark.svg   horizontal lockup
#   Assets/brand/og-image.svg   1200x630 Open Graph card
set -euo pipefail
cd "$(dirname "$0")/.."

RENDER="swift Scripts/render-svg.swift"
STAGE_CROP="--crop 100 100 824 824"   # the icon's squircle without its margin
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/screenreel-icons.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

build_icns() {
    local out="$1"
    local iconset="$SCRATCH/AppIcon.iconset"
    rm -rf "$iconset"; mkdir -p "$iconset"
    # 16 px and 32 px @1x (and 16 @2x, which is 32 px) use the simplified art;
    # 64 px and up use the full icon.
    $RENDER Assets/AppIcon-small.svg "$iconset/icon_16x16.png"      16
    $RENDER Assets/AppIcon-small.svg "$iconset/icon_16x16@2x.png"   32
    $RENDER Assets/AppIcon-small.svg "$iconset/icon_32x32.png"      32
    $RENDER Assets/AppIcon.svg       "$iconset/icon_32x32@2x.png"   64
    $RENDER Assets/AppIcon.svg       "$iconset/icon_128x128.png"    128
    $RENDER Assets/AppIcon.svg       "$iconset/icon_128x128@2x.png" 256
    $RENDER Assets/AppIcon.svg       "$iconset/icon_256x256.png"    256
    $RENDER Assets/AppIcon.svg       "$iconset/icon_256x256@2x.png" 512
    $RENDER Assets/AppIcon.svg       "$iconset/icon_512x512.png"    512
    $RENDER Assets/AppIcon.svg       "$iconset/icon_512x512@2x.png" 1024
    mkdir -p "$(dirname "$out")"
    iconutil -c icns "$iconset" -o "$out"
    echo "wrote $out"
}

if [ $# -eq 1 ]; then
    build_icns "$1"
    exit 0
fi

build_icns Assets/AppIcon.icns

$RENDER Assets/AppIcon.svg Assets/AppIcon-1024.png 1024
echo "wrote Assets/AppIcon-1024.png"

# Menu-bar mark: the "Template" suffix makes AppKit treat it as a template
# image (black on transparent, tinted by the system).
$RENDER Assets/MenuBarIcon.svg Assets/MenuBarIconTemplate.png    18
$RENDER Assets/MenuBarIcon.svg Assets/MenuBarIconTemplate@2x.png 36
echo "wrote Assets/MenuBarIconTemplate.png, @2x"

# Website: the squircle without the Dock margin/shadow (full-bleed, rounded
# transparent corners), plus the Open Graph card.
mkdir -p website/assets
$RENDER Assets/AppIcon.svg website/assets/icon.png    1024 $STAGE_CROP
$RENDER Assets/AppIcon.svg website/assets/favicon.png 64   $STAGE_CROP
$RENDER Assets/brand/og-image.svg website/assets/og-image.png 1200 630
echo "wrote website/assets/icon.png, favicon.png, og-image.png"
