# Product specification

## 1. Outcome

Screenreel lets a lecturer or technical creator record once, edit quickly, and reliably export a readable 4K video with clear speech, a legible cursor, and restrained automatic zooms. A 45-minute lecture should feel as safe as saving a document: the raw work survives a crash and rendering can resume.

## 2. Primary users

### Lecturer

Records slides, handwriting, equations, code, and browser demos for 30–90 minutes. Needs 4K slide legibility, microphone recovery, cursor visibility, and a predictable file size more than flashy effects.

### Technical educator

Combines terminal/code/browser actions with narration. Needs click-driven zooms, cursor smoothing, keyboard overlays, cuts, and fast proof exports.

### Product demonstrator

Needs backgrounds, frames, camera layouts, vertical/square reframing, masks, captions, and a polished short export.

The lecturer is the v0.1 priority. Short-form polish must not weaken long-form reliability.

## 3. Core workflows

### A. Record

1. Choose display, window, or area.
2. Choose microphone, system audio, optional camera, frame rate, and storage location.
3. See live meters and a disk-time estimate.
4. Record after a three-second countdown; pause/resume is allowed.
5. Stop and immediately open an already-valid project. Proxy/audio enhancement may continue as background jobs.

### B. Recover

1. On launch, detect incomplete sessions from the journal.
2. Show the last durable timestamp and available tracks.
3. Offer **Recover a copy**; never alter the evidence first.
4. Validate segments, rebuild indexes/waveforms/proxies, and open the recovered project with a report.

### C. Edit

1. Play immediately from a proxy or raw fallback.
2. Trim/split/reorder clips without changing raw files.
3. Choose a visual preset or adjust canvas/background/screen treatment.
4. Generate zooms from click data, then move/resize/disable/add ranges.
5. Tune cursor, audio enhancement, track levels/offsets, camera, captions, masks, and text.
6. Export a proof range from the exact current composition.

### D. Export

1. Choose MP4 H.264/HEVC, resolution, frame rate, and target quality/file size.
2. See projected size, free-space need, estimated speed, and any missing asset warnings.
3. Render with accurate frame/stage progress; pause/cancel safely.
4. Resume after app relaunch or retry a failed segment.
5. Validate the final video before announcing success.

## 4. Feature priorities

| Area | v0.1 must | v0.2 should | Later |
|---|---|---|---|
| Capture | display/window/area, mic, system audio, cursor/click data, pause/resume | separate camera, keyboard events | iOS capture, cross-platform |
| Safety | segmented assets, journal, autosave, recovery, validator | rolling backup location | cloud backup |
| Edit | trim/split, audio offsets, canvas/background, cursor, zoom track | masks, captions, camera scenes, text | general NLE/audio plug-ins |
| Audio | raw track, local denoise/normalize, cache, bypass | EQ/compressor presets, music lanes | voice isolation variants |
| Motion | click auto-zoom, manual zoom, cursor smoothing/size/hide | tilt, motion blur, click sound, keyboard overlay | scene-aware zoom suggestions |
| Export | proof range, 720/1080/4K, 15/30/60, H.264/HEVC, checkpoint/resume | GIF/MOV alpha, presets | direct cloud publish |

## 5. Visual editing controls

- Output aspect: Auto, 16:9, 9:16, 1:1, 4:3, 3:4, and custom.
- Screen crop and placement with numeric inspector values.
- Background: none/transparent, color, gradient, user image, desktop wallpaper snapshot.
- Screen treatment: padding, inset, corner radius/style, border, shadow, background blur, motion blur.
- Optional chrome: no frame, generic macOS/Windows frame, browser chrome with editable title/URL, laptop bezel. Ship only original/generic assets.
- Presets save visual/audio/motion defaults but never replace timeline clips or source media.

## 6. Cursor and zoom controls

- Cursor: show/hide, scale, original/default/touch style, idle-hide delay, raw/smoothed motion, custom spring values, optional tilt, click squash/ring/sound.
- Preserve captured cursor type and hotspot; a style override is non-destructive.
- Zoom track: generate from clicks, manual segment, auto/manual focal point, 1.0–4.5× scale, resize/move/duplicate/disable/delete, instant or spring transition.
- Reframing applies one camera transform to screen, cursor, masks anchored to screen coordinates, and screen-relative annotations.

## 7. Audio controls

- Separate microphone and system-audio tracks with mute, gain, and offset.
- Raw/enhanced A/B, enhancement amount or bypass, waveform, clipping warning, loudness estimate.
- Enhancement is a cached derivative; changing a setting invalidates only the derivative.
- Default v0.1 speech preset: DeepFilterNet3 denoise followed by conservative speech normalization. See `AUDIO_PIPELINE.md`.

## 8. Export presets

### Lecture 4K (default for slides/math)

- 3840×2160 or source-constrained 4K canvas, 30 fps.
- H.264 High Profile via VideoToolbox; HEVC offered for smaller files.
- AAC 48 kHz, mono for mic-only or stereo when system audio is present.
- Quality target starts around 8–12 Mb/s for mostly static slides and adapts upward for motion.
- Always run a size estimate and warn if projected free space is less than 2.5× the final file plus cache.

### Social 4K

- Same readable 4K canvas with a lower size target, slower optional final pass, and no loss of text sharpness.
- Explicit target-size control; never silently lower resolution.

### Proof

- Selected 15–30 seconds, same geometry/timing/audio graph, fast hardware encode.

## 9. UX requirements

- The record button is never enabled until chosen audio inputs show a signal or the user explicitly accepts silence.
- A visible red recording indicator and duration live outside the captured region when possible.
- The editor opens before enhancement/proxy generation finishes and clearly labels temporary quality.
- Export progress reports stage + completed frames/total frames + output path + remaining disk.
- “Stuck” means no durable progress for 30 seconds; surface diagnostics and a safe retry instead of a frozen percentage.
- Success means the final file exists, is readable, contains expected video/audio streams, and passes duration checks.

## 10. Non-goals and product boundaries

- No automatic upload in v0.1.
- No server account is required to record, edit, enhance, or export.
- No destructive cleanup of project assets from inside the first release.
- No frame-perfect multi-cam professional NLE scope.
- No claim of compatibility with other products' project formats.

## 11. Success metrics

- 0 lost raw recordings in 100 forced-quit capture tests.
- 95% of ordinary projects reach a proof export within two minutes of stopping.
- A one-hour 4K30 lecture exports at >=0.5× real time on the target Apple Silicon baseline and can resume after a forced quit.
- Cursor alignment error <1 output pixel for deterministic fixtures at 100% scale and <2 pixels under zoom.
- A/V end-time drift <20 ms per hour; start offset is explicit and editable.
- User can locate and open every raw track without Screenreel.
