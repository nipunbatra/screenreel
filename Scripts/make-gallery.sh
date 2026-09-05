#!/bin/bash
# Build a public-safe teaching demo with the app's real engines.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_PATH="${BUILD_PATH:-.build/distribution}"
OUTPUT="${1:-.build/gallery-media}"
swift build -c release --scratch-path "$BUILD_PATH" --jobs 2
BIN="$(swift build -c release --scratch-path "$BUILD_PATH" --show-bin-path)"
objects=()
for module in ProjectModel Diagnostics EventCapture CaptureCore TimelineCore MotionEngine RenderGraph PreviewEngine AudioPipeline ExportEngine; do
    for object in "$BIN/$module.build/"*.o; do objects+=("$object"); done
done
swiftc -O -parse-as-library -I "$BIN/Modules" Scripts/make-gallery.swift "${objects[@]}" -o "$BIN/make-gallery"
"$BIN/make-gallery" "$OUTPUT"
