#!/bin/bash
# Compile a media helper against already-built production release modules.
set -euo pipefail
cd "$(dirname "$0")/.."
source_file="$1"
shift
build_path="${BUILD_PATH:-.build/distribution}"
bin="$(swift build -c release --scratch-path "$build_path" --show-bin-path)"
objects=()
for module in ProjectModel Diagnostics EventCapture CaptureCore TimelineCore MotionEngine RenderGraph PreviewEngine AudioPipeline ExportEngine; do
    for object in "$bin/$module.build/"*.o; do objects+=("$object"); done
done
helper="$bin/$(basename "$source_file" .swift)"
swiftc -O -parse-as-library -I "$bin/Modules" "$source_file" "${objects[@]}" -o "$helper"
"$helper" "$@"
