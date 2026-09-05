# Homepage feature gallery

The homepage shows the native editor and six equal-size 16:9 demos: silent
window capture, imported music, original and cleaned voice, editable zoom,
and three frame treatments. PNG screenshots open at full size. Optional
4-second GIF excerpts are linked rather than animated in the background.

## Media provenance

`Scripts/gallery-wave-lab.swift` is a small native Mac app with an animated
waveform and real buttons. It is the subject of an **actual ScreenCaptureKit
window capture**, using Screen Reel's production CLI. No generated pixel
source or generated cursor events are substituted for captured video.

The silent and music clips share one real take. `Scripts/record-voice-demo.swift`
records the actual Wave Lab window while feeding a clearly labeled controlled
voice file to the microphone-track writer. The voice is macOS Samantha speech
with seeded white noise; it does not access a physical microphone. Both voice
clips export the same project with `micNoiseReduction` off/on. The soundtrack
is an original synthesized instrumental loop imported through `MusicAsset`.

`Scripts/export-real-gallery.swift` renders through `StyledExporter` and
`ProjectComposition`. The style comparison holds three exported stills for
two seconds each. Editor PNGs are actual WindowServer captures of the running
app, including its Metal preview and native toolbar. The music inspector
screenshot was captured after changing volume, toggling looping, removing
music and restoring it with Undo in the UI. The full-resolution capture PNG
uses the new screenshot command. PNG optimization is lossless.

Only purpose-made public demo content is published. The separate system-audio
capture used for local verification and all project packages remain in `.build/`.
No microphone, webcam, personal desktop, account or lecture content is published.

## Reproduction

Build the release products with `Scripts/make-app.sh` and
`swift build -c release --scratch-path .build/distribution --jobs 2`.
Compile `gallery-wave-lab.swift` as an AppKit executable inside a small app
bundle. Run it, then list its window with `screenreel sources`. Keep the demo
window visible while recording and interact with its waveform buttons.

```sh
screenreel record --window WINDOW_ID --no-mic --duration 13 \
  --output '.build/real-gallery/Silent window.screenreel'
screenreel screenshot .build/real-gallery/capture.png --window WINDOW_ID
bash Scripts/run-gallery-helper.sh Scripts/record-voice-demo.swift WINDOW_ID .build/real-gallery
bash Scripts/run-gallery-helper.sh Scripts/export-real-gallery.swift .build/real-gallery
SCREENREEL_AUTOPILOT_DIR="$PWD/.build/gallery-checks/editor-030" \
SCREENREEL_AUTOPILOT_PROJECT="$PWD/.build/real-gallery/Silent window.screenreel" \
SCREENREEL_AUTOPILOT_MUSIC="$PWD/.build/real-gallery/demo-music.wav" \
  'dist/Screen Reel.app/Contents/MacOS/Screen Reel'
# Wait for report.txt = PASS. Capture the audio inspector of this demo project
# with screenreel screenshot, then close only the harness process you launched.
bash Scripts/prepare-real-gallery-media.sh
node --test Tests/WebsiteTests/*.test.mjs
python3 Tests/WebsiteTests/test_assets.py
```

Use fresh recording package paths; capture refuses to overwrite a project.
The harness edits a copy. The controlled audio fixtures are local build inputs,
not bundled third-party media or licensed songs.

## Loading, accessibility and regression gates

All videos use native controls, fixed 1280×720 dimensions, `preload="none"`,
and no autoplay. Explicit audio buttons enable sound and replay the comparison
from its beginning. Only one video plays at once; hidden pages and offscreen
videos pause without automatic resumption. GIFs and MP4s have direct fallback
links. Screenshot links work without JavaScript; enhanced dialogs support Escape.

The Pages workflow runs playback lifecycle tests and offline HTML/media gates.
These verify local links, accessibility names, dimensions, audio track presence,
muted defaults, real animated GIFs, fast-start MP4 metadata and download budgets.
