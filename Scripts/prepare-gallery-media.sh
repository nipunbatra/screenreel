#!/bin/bash
# Web encodings of production exports and native app harness screenshots.
# Requires ffmpeg. Originals stay in the supplied build directories.
set -euo pipefail
cd "$(dirname "$0")/.."
MEDIA="${1:-.build/gallery-media}"
SHOTS="${2:-.build/gallery-checks/editor}"
OUT=website/assets/gallery
mkdir -p "$OUT"
for name in zoom cursor; do
    ffmpeg -v error -y -i "$MEDIA/$name.mp4" -an -c:v libx264 -threads 2 -preset slow -crf 23 -pix_fmt yuv420p -movflags +faststart "$OUT/$name.mp4"
    ffmpeg -v error -y -ss 0 -i "$OUT/$name.mp4" -frames:v 1 "$OUT/$name.png"
    ffmpeg -v error -y -i "$OUT/$name.mp4" -filter_complex 'fps=10,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' -loop 0 "$OUT/$name.gif"
done
ffmpeg -v error -y -loop 1 -t 2 -i "$MEDIA/style-sage.png" -loop 1 -t 2 -i "$MEDIA/style-clay.png" -loop 1 -t 2 -i "$MEDIA/style-ink.png" -filter_complex '[0:v][1:v][2:v]concat=n=3:v=1:a=0,fps=15,format=yuv420p[v]' -map '[v]' -an -c:v libx264 -threads 2 -preset slow -crf 22 -movflags +faststart "$OUT/styles.mp4"
ffmpeg -v error -y -i "$OUT/styles.mp4" -filter_complex 'fps=2,scale=640:-2:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' -loop 0 "$OUT/styles.gif"
ffmpeg -v error -y -i "$MEDIA/style-sage.png" "$OUT/style.png"
ffmpeg -v error -y -i "$SHOTS/2-editor.png" "$OUT/editor.png"
ffmpeg -v error -y -i "$SHOTS/4-restyled.png" "$OUT/editor-styled.png"
