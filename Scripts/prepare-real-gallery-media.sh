#!/bin/bash
# Compact encodings of actual captures exported by export-real-gallery.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
media="${1:-.build/real-gallery}"
shots="${2:-.build/gallery-checks/editor-030}"
out=website/assets/gallery
for name in window music voice-original voice-clean zoom; do
    ffmpeg -v error -y -i "$media/$name.mp4" -c:v libx264 -threads 2 -preset slow -crf 23 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$out/$name.mp4"
    ffmpeg -v error -y -ss 1 -i "$out/$name.mp4" -frames:v 1 -compression_level 9 "$out/$name.png"
done
ffmpeg -v error -y -loop 1 -t 2 -i "$media/style-sage.png" -loop 1 -t 2 -i "$media/style-clay.png" -loop 1 -t 2 -i "$media/style-ink.png" -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0,fps=15,format=yuv420p[v]' -map '[v]' -an -c:v libx264 -threads 2 -preset slow -crf 22 -movflags +faststart "$out/styles.mp4"
cp "$media/style-sage.png" "$out/styles.png"
for name in window zoom styles; do
    ffmpeg -v error -y -i "$out/$name.mp4" -t 4 -filter_complex 'fps=8,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' -loop 0 "$out/$name.gif"
done
cp "$media/capture.png" "$out/capture.png"
ffmpeg -v error -y -i "$shots/2-editor-window.png" -frames:v 1 -compression_level 9 -pred mixed "$out/editor.png"
# Capture the audio inspector with screenreel screenshot after the native UI check.
audio_shot="${3:-.build/gallery-checks/review-030/music-controls-window.png}"
ffmpeg -v error -y -i "$audio_shot" -frames:v 1 -compression_level 9 -pred mixed "$out/editor-styled.png"
# Superseded generated-board media; never touches project recordings.
rm -f "$out/cursor.mp4" "$out/cursor.gif" "$out/cursor.png" "$out/style.png"
