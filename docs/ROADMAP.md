# Implementation roadmap

The order is intentional. Do not build the beautiful editor on top of a fragile recording file.

## Milestone 0 — Durable recorder and validator

### Deliver

- Swift package/module skeleton and macOS shell.
- Display/window/area selection and permissions.
- Segmented raw screen, microphone, and system-audio capture.
- Shared monotonic clock and per-stream timestamp diagnostics.
- Cursor/click event capture with descriptor/hotspot records.
- Versioned manifest, journal, atomic writes, and schema fixtures.
- `screenreel validate`, `screenreel recover`, and `screenreel extract` commands.
- Minimal session UI: source selectors, meters, disk estimate, countdown, pause/resume/stop, fault warnings.

### Exit

All Milestone 0 gates in `ACCEPTANCE_TESTS.md` pass, including forced quit and missing microphone tests. A recovered project is playable from raw segments without the GUI.

## Milestone 1 — Read-only editor and proof render

### Deliver

- Project browser/recovery prompt.
- Timeline playback over segments with audio-clock sync.
- Proxy and waveform jobs.
- RenderGraph and Metal preview.
- Background, crop, padding, corner, border, and shadow controls.
- Raw cursor rendering with exact descriptors/hotspots.
- 20-second proof MP4 export and validator.

### Exit

Accurate preview and proof export pass pixel/timing fixtures. Editor opens within the target even while proxies build.

## Milestone 2 — Non-destructive edits, motion, and audio

### Deliver

- Trim/split/reorder and undo/redo.
- Mic/system mute/gain/offset.
- DeepFilterNet3 enhancement job, cache, raw/enhanced A/B.
- Cursor smoothing/scale/idle hide/click effects.
- Automatic zoom generation, manual zooms, inspector, deterministic camera springs.
- Presets with concrete versioned values.

### Exit

Long fixture edits survive relaunch, seek deterministically, and match export. Audio quality/sync fixtures pass.

## Milestone 3 — Resilient full export

### Deliver

- Frozen export snapshot and job UI.
- H.264/HEVC VideoToolbox export at 720p/1080p/4K and 15/30/60 fps.
- Segmented render, checksums, cancellation, retry, resume, assembly, final validation.
- Quality and target-size modes, storage forecast, real progress/ETA, diagnostics.

### Exit

One-hour 4K test exports at the performance target; forced quits at each stage resume to a valid output; output survives ffprobe/decode/A-V tests.

## Milestone 4 — Teaching polish

### Deliver

- Camera capture/layout and scene track.
- Masks/highlights, text lanes, keyboard overlay.
- Local captions and SRT/VTT import/export.
- Additional aspect ratios/frames, motion blur, click sound, multiple music lanes. One portable background music track is available in 0.3.0.
- GIF and optional alpha cursor-only MOV.

### Exit

Feature interactions have fixtures, privacy controls pass review, and no feature breaks the recovery/export gates.

## Later

- Windows capture/editor strategy.
- Local MCP/CLI automation for record/render/publish.
- Optional share/publisher adapters, including YouTube, with explicit authentication/privacy.
- Collaboration, comments, analytics, and self-hosted web playback only if product demand justifies a server.

## Decisions required before public release

- Repository/software license.
- Minimum macOS and hardware baseline.
- Distribution, signing, notarization, update channel.
- DeepFilterNet model packaging/download and attribution.
- Cursor/vector/background asset licenses.
- Whether keyboard capture ships enabled at all and its secure-input/privacy review.

