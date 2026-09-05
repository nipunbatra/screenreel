# Screen Reel 0.3.0 — capture, music and actual demos

## Delivered

- PNG screenshots of the selected display, window, app or area through the
  native recorder and CLI; native Retina pixels, no recording session needed.
- One portable background music track with import, volume, looping, replacement,
  removal and undo. Preview and normal/checkpointed styled exports use the same
  output timeline. The Include audio control produces silent exports.
- CLI source listing/selection, separate webcam capture, screenshot and music
  commands. Old projects still decode without music and originals are preserved.
- Static silent recordings retain their final still through Stop without
  holding an extra SCK surface or continuously encoding duplicates.
- Camera authorization is checked/requested before opening the device. Camera
  startup failure and an empty enabled camera track cannot quietly succeed.
- Six equal-size actual recording/export demos, native editor/audio inspector
  screenshots, three GIF downloads and a feature list on the homepage.

Website: [Screen Reel gallery](https://nipunbatra.github.io/screenreel/#gallery).
Release: [Screen Reel 0.3.0](https://github.com/nipunbatra/screenreel/releases/tag/v0.3.0).

The final app and DMG are Developer ID signed, notarized and Gatekeeper
accepted, including strict validation of the app mounted from the installer.
The installed `/Applications/Screen Reel.app` is 0.3.0, independently stapled
and verified; its previous version is copied under `.build/gallery-checks/installed-before-030.app`.
DMG SHA-256: `7326ea10e67aa94e5e460dddc03ae48bff29cca22574d33f69e5f61e8d33098f`.

## Verification

- Final full Swift suite: **550 tests, three intentional skips, zero failures**.
  The skipped checks are ten-minute 4K capture, thirty-minute export and fixture
  regeneration. Prior long-run evidence is documented in BENCHMARKS.md; it was
  not re-measured for this release. Real recording preview/export parity passed.
- Fifteen new Swift checks cover conversion, portable originals, gain, looping,
  missing music, normal/checkpointed export parity, silent output, source
  geometry, static-screen timing, CLI validation and camera permissions.
- 22 website checks pass: 12 playback lifecycle cases and 10 offline media,
  accessibility, link and byte-budget gates. Six real MP4s are 1280×720;
  three contain the intended audio tracks and three are silent. Gallery assets
  total 5,400,143 bytes; no video exceeds 1 MB. PNG compression is lossless.
- Browser review at 1280, 768 and 390 px: all six videos have matching heights,
  no horizontal overflow, no video loaded before request, audible buttons
  restart/unmute, only one video plays, offscreen playback pauses, and image
  dialogs dismiss with Escape and restore focus. No console errors or warnings.
- Native app harnesses passed open, decode, playback, zoom re-aim, music import,
  gain change and styled export. Hands-on music loop, removal, undo and volume
  changes passed. Actual WindowServer screenshots include the Metal preview.
- Live screenshot output: window/area 1920×1148, app 4096×2304 PNG. The actual
  13.44-second silent window recording has 381 frames, zero drops, 5.09% mean
  process CPU and 42.3 MiB peak RSS. These are short observations, not a claim
  of whole-system performance or parity with another recorder.
- The controlled voice demo’s final noise interval drops about 20 dB after
  export cleanup. It uses stock computer speech plus seeded hiss, clearly
  labeled on the page. No personal audio or webcam content is published.

## Remaining device check

The first local physical-camera test exposed a missing permission request:
its camera track was empty but validation reported healthy. This is fixed and
covered by the new tests. After the user reported granting access, this agent’s
command-line host still waited for the authorization callback, including after
restart. Those idle test processes were stopped; physical camera footage was
not verified. Test the installed app from a normally authorized Mac session.
The CLI uses the invoking terminal’s separate macOS device permissions.

## Evidence and maintenance

Local logs and public-safe capture projects remain under `.build/gallery-checks/`
and `.build/real-gallery/`. Camera attempts stay local and ignored. See
[gallery provenance](FEATURE_GALLERY.md), [benchmarks](BENCHMARKS.md), and
[decisions 0010](decisions/0010-screenshots-and-portable-music.md) and
[0011](decisions/0011-static-screen-duration.md). Original recordings and imported
music are ordinary files inside the open project package.
