# Acceptance tests and release gates

## 1. Test assets

Check in or generate small, rights-safe fixtures:

- color bars/grid/text at source corners and center;
- 4K slide deck fixture with 8–24 pt text and equations;
- deterministic cursor events for arrow/I-beam/hand with known hotspots;
- click clusters, drag, idle, display edge, and rapid motion;
- mono speech-like signal, stereo system audio, silence, impulse sync marker, fan/keyboard noise;
- projects with cuts, offsets, zooms, and corrupted/missing segments;
- schema fixtures for every released format version.

Large generated media stays out of Git; store generator inputs/seeds and expected hashes/measurements.

## 2. Milestone 0 gates

### Capture integrity

- Record 10 minutes at 4K30 with mic/system audio/events; every committed segment opens independently.
- Join/logical playback duration is within one frame of expected video duration.
- Mic and system-audio streams are present, non-empty, and correctly labelled.
- Inject callback pressure; dropped frames/buffers are counted and reported, not hidden.
- Change microphone route/format; a new descriptor/segment is created and capture continues or fails explicitly.

### Forced termination matrix

Force quit/power-loss simulation during:

- open screen segment;
- open audio segment;
- event chunk write;
- manifest replacement;
- pause and resume;
- normal finalization.

On relaunch, recovery identifies committed data, never changes it before making a copy, and produces a playable project through the last safe segment. Repeat each point at least ten times in automation where possible.

### Missing audio

- Disable/withdraw mic samples after start: live warning appears within two seconds and is journaled.
- Stop/export path refuses to call a mic-enabled project healthy when the mic track is absent/empty.
- Explicit “record without microphone” remains valid and visibly labelled.

### Clock

- A one-hour synthetic capture yields <20 ms A/V drift.
- Pauses, gaps, and source discontinuities are explicit.
- Wall-clock changes/time-zone changes do not affect timeline time.

## 3. Milestone 1 gates

- Project opens to a visible frame in <2 s with a proxy and <5 s with raw fallback on baseline hardware.
- Seek to 100 deterministic times; returned frame/event state matches linear playback.
- Accurate preview vs proof export: mean absolute pixel error and edge tolerances are documented; geometry/cursor hotspot error <=1 pixel at native scale.
- Background, padding, crop, corners, border, and shadow match golden fixtures at 1080p and 4K.
- Proof file contains expected H.264 video/AAC audio, dimensions, frame count policy, and duration.

## 4. Milestone 2 gates

### Timeline

- Random sequences of split/trim/reorder/undo/redo round-trip through save/reload.
- Events/zooms/audio remain correctly mapped at cut and speed boundaries.
- No edit changes a raw asset checksum.

### Motion

- Spring reference values match stored numerical fixtures at frame times.
- Random seek equals play-through state.
- Cursor sprite/hotspot is correct across cursor-type changes and zooms.
- Auto zoom generator produces expected ranges for single, clustered, tail, cut-boundary, and drag fixtures.
- Screen and cursor share the same camera transform within the pixel tolerance.

### Audio

- Raw/enhanced A/B is time-aligned within 1 ms at start/end markers.
- Enhancement cache invalidation responds only to relevant keys.
- Final lecture preset meets configured loudness/peak limits without clipped samples.
- Human fixture review rates noise reduction as helpful without unacceptable speech damage; raw is always selectable.

## 5. Milestone 3 gates

### Export correctness

- Matrix: H.264/HEVC × 1080p/4K × 30/60 fps × mic-only/mic+system.
- `ffprobe` output matches job settings; first/middle/last frames decode.
- Expected audio exists and non-silent ratio passes.
- A/V end difference <= one video frame +10 ms.
- No non-monotonic/negative timestamps after final mux.

### Resume/failure

Force quit during preparation, enhancement, segment render, assembly, validation, and final rename. Resume reuses only valid committed work and produces the same logical output as an uninterrupted job. Cancel never damages the project or an existing destination file.

### Long form

- One-hour 4K30 slide/math project stays within memory/disk bounds.
- Export average speed >=0.5× real time on the selected baseline Apple Silicon Mac.
- Progress advances with committed work; a deliberately hung encoder is marked `attentionNeeded` within 30 seconds.
- Disk exhaustion pauses/fails safely at a boundary and resumes after space is made.

### Determinism

Two runs on the same engine/hardware/settings may differ at codec bytes, but decoded frame hashes/metrics, event state, timing, frame count, and audio measurements match documented tolerances.

## 6. Release checklist

- All automated tests pass on clean machines for every supported macOS version.
- Screen Recording, Microphone, Accessibility, and optional Camera permission flows are tested from denied/limited/granted states.
- App operates offline after any explicitly optional model install.
- Raw extraction is tested without launching the GUI.
- Diagnostic bundle contains no screen pixels, audio, keys, tokens, or unrelated filenames by default.
- License/attribution inventory is complete.
- Signing/notarization/update rollback tests pass.

