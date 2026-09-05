# Homepage feature gallery

The homepage presents the native editor, editable zooms, cursor/click effects,
and three background treatments. Two editor PNGs can be enlarged in a native
HTML dialog. Three silent clips are available inline as H.264 MP4 and as small
GIF downloads. The earlier interactive framing illustration is still below
this gallery; its controls continue to work independently.

## Content provenance

Every published asset under `website/assets/gallery/` uses the purpose-made
**A clear explanation** project. It contains a generated teaching board,
generated cursor/click events and a generated tone for the editor's waveform.
No desktop screenshot, microphone, camera, lecture recording, account data or
other personal file is included. Public videos contain no audio track.

`Scripts/make-gallery.swift` draws the board, passes frames through the real
`CaptureSession`, stores events with `EventChunkStore`, and renders the clips
through `StyledExporter`/`ProjectComposition`. The framing sequence shows
three exported still frames held for two seconds each. These are examples of
exported output, not fabricated recordings of someone clicking the app UI.

Editor screenshots are the app's native view snapshots from its existing
`Autopilot` harness. The actual preview frame is read back from its Metal
surface because AppKit's view snapshot alone omits CAMetalLayer content.
The screenshots show the editor content; the separate WindowServer captures
were black on this host and are not used. No image generator or mock app UI
was used for the product screenshots.

## Reproduce

Requires the project's normal Swift toolchain and `ffmpeg`; no website build
system or npm dependencies are needed. Use a fresh output directory because
project creation deliberately refuses to overwrite a recording.

```sh
Scripts/make-gallery.sh .build/gallery-media
Scripts/make-app.sh
SCREENREEL_AUTOPILOT_DIR="$PWD/.build/gallery-checks/editor" \
SCREENREEL_AUTOPILOT_PROJECT="$PWD/.build/gallery-media/A clear explanation.screenreel" \
SCREENREEL_AUTOPILOT_PLAY_SECONDS=5 \
  'dist/Screen Reel.app/Contents/MacOS/Screen Reel'
# After report.txt says PASS, close the harness app.
Scripts/prepare-gallery-media.sh .build/gallery-media .build/gallery-checks/editor
node --test Tests/WebsiteTests/*.test.mjs
python3 Tests/WebsiteTests/test_assets.py
```

The harness edits a copy under its output directory. Original project files
remain under `.build/` and are never committed. Final web assets are the only
exception to the repository's general MP4 ignore rule.

## Loading and accessibility

- Native video controls, mute, inline playback and static posters. No autoplay.
- `preload="none"`; videos remain at readyState 0 until requested in the
  verified browser. GIFs are download links and consume no animation CPU on
  the homepage.
- One active video; native controls and the explicit play buttons share the
  same lifecycle. Leaving the viewport or hiding the page pauses playback.
  Returning never starts it automatically.
- Screenshot links work without JavaScript. With JavaScript, a labeled HTML
  dialog opens; Escape closes it and restores focus to the original link.
  Modified clicks retain the browser's usual open-in-another-tab behavior.
- Native MP4/GIF links remain available if inline playback fails. Controls
  announce errors through a polite status region.
- Fixed intrinsic image/video dimensions prevent layout jumps. Responsive
  single-column gallery on small screens; no horizontal overflow at 390,
  768 or the default 1280 px viewport.

Before each Pages deploy, CI runs ten playback tests and eight HTML/media
checks. These include missing files/anchors, duplicate IDs, accessible names,
no-autoplay defaults, real animated GIF headers, MP4 fast-start metadata,
screenshot dimensions and per-file/total byte budgets. The gallery adds
about 1.9 MiB including optional GIFs; the three MP4s together are about
257 KiB. Only requested media is decoded.
