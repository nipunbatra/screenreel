# Screenreel

**An open-source, Mac-native recording studio: automatic zooms, cuts, captions, and camera scenes — computed on your Mac, on top of a recorder that never loses a take.**

Screenreel pairs studio-grade visual polish with a fully local, open workflow, built on a render pipeline that finishes a 30–90 minute 4K lecture without losing its audio, cursor, or project state. The app installs as **Screenreel.app**; the project format (`.aks`) and bundle identifier keep their original historical identifiers so existing projects and permission grants stay valid. Everything here is a fresh implementation — original code, original artwork.

## Product promise

1. **Safe before stylish.** Screen, microphone, system audio, camera, cursor events, clicks, and metadata are persisted as separate recoverable assets while recording.
2. **Polish stays editable.** Cursor smoothing, click effects, zooms, backgrounds, padding, corners, shadows, masks, and captions are non-destructive project data.
3. **Fast preview, dependable export.** Editing uses proxies and reduced effects. Final export is deterministic, hardware accelerated, checkpointed, cancellable, and resumable.
4. **The project is open.** A project is a documented folder/package. Even if Aks will not launch, the raw media can be opened with ordinary tools.

## First release

Aks v0.1 is Mac-first and local-first:

- record a display, window, or area with microphone and system audio;
- capture cursor shape, hotspot, movement, clicks, and optional keyboard events separately;
- reopen and recover an interrupted recording;
- trim/split clips and correct audio offsets;
- apply a background, crop, padding, rounded corners, border, and shadow;
- generate editable click-driven zooms and render a smoothed cursor;
- enhance microphone audio locally while keeping the raw track;
- export a proof segment or a full H.264/HEVC 4K MP4;
- show real progress, disk forecasts, logs, and a resumable checkpoint.

Cloud sharing, team workspaces, AI chapters, stock media, Windows support, and a general-purpose nonlinear editor are deliberately deferred.

## Read in this order

- [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md) — audience, workflows, scope, and feature priorities
- [`docs/TECHNICAL_DESIGN.md`](docs/TECHNICAL_DESIGN.md) — architecture and subsystem boundaries
- [`docs/PROJECT_FORMAT.md`](docs/PROJECT_FORMAT.md) — versioned, recovery-oriented on-disk format
- [`docs/AUDIO_PIPELINE.md`](docs/AUDIO_PIPELINE.md) — capture, enhancement, sync, caching, and QA
- [`docs/MOTION_ENGINE.md`](docs/MOTION_ENGINE.md) — cursor and zoom generation/rendering
- [`docs/EXPORT_PIPELINE.md`](docs/EXPORT_PIPELINE.md) — preview and resilient 4K export
- [`docs/ACCEPTANCE_TESTS.md`](docs/ACCEPTANCE_TESTS.md) — objective release gates
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — build sequence
- [`CLAUDE.md`](CLAUDE.md) — implementation-agent contract

## Recommended architecture

- SwiftUI + AppKit for the macOS application and editor shell.
- ScreenCaptureKit for display/window/system-audio capture.
- AVFoundation/Core Audio for microphone capture, timestamps, muxing, and inspection.
- Metal/Core Image for the shared preview/export composition graph.
- VideoToolbox for hardware H.264/HEVC encode.
- A small Rust helper or packaged CLI for DeepFilterNet, added only after raw capture and recovery are proven.

All code in this repository is original and MIT-licensed. Contributions must not copy code or assets from other screen-recording products, whatever their license.

## Start here

The first implementation milestone is not the editor. It is a segmented, crash-recoverable recorder plus a validator. Follow [`CLAUDE.md`](CLAUDE.md) and [`docs/ROADMAP.md`](docs/ROADMAP.md).

## Status: recorder, editor, and exporter working (macOS 15+, Swift 6)

Milestone 0 (durable recorder + validator) is implemented and gated, and the
first editor/export slice on top of it works end to end. See
[`docs/decisions/`](docs/decisions/) for the ADRs.

**The app** (recorder + editor):

```bash
Scripts/make-app.sh          # builds "dist/Screen Record.app"
open "dist/Screen Record.app" # grant Screen Recording, Microphone, Input Monitoring
```

Recording starts from wherever you are: the always-on menu bar item
(Record Screen / Record Window… / Record Area… / Recent), the global
shortcuts ⇧⌘R (start/stop), ⇧⌘P (pause/resume) and ⇧⌘A (draw an area on
screen and record it) — they work while any app is frontmost and need no
extra permission — or the start screen. Every start shows an on-screen
countdown (Esc cancels, click starts now). Settings (⌘,) covers the menu
bar item, shortcut presets, countdown length (off/3/5 s), the recordings
folder, and whether stopping opens the editor.

Record a display (the app's own windows are excluded from capture), then edit:
background presets, padding, rounded corners, shadow, smoothed cursor with
click squash, click-driven auto-zooms (editable per segment), trim, live
composed preview with raw-mic audio, and one-click export to MP4 — styled
(re-encode through the same composition the preview shows) or raw (lossless
stream copy at ~20× real time).

**The CLI**:

```bash
swift build -c release
.build/release/aks env                       # environment + capturable displays
.build/release/aks record                    # real capture until Ctrl-C
.build/release/aks record --synthetic --duration 30 --pace 1   # no permissions needed
.build/release/aks export    <project.aks>            # raw assembly to MP4
.build/release/aks export    <project.aks> --styled   # edits rendered in
.build/release/aks validate  <project.aks>   # checksums, journal chain, decode probes
.build/release/aks recover   <project.aks>   # crash recovery to a fresh copy
.build/release/aks extract   <project.aks> <dir>   # raw media + events.csv/json
.build/release/aks inspect   <project.aks> --journal
```

A recording is a `.aks` package: 4-second finalized HEVC/H.264 `.mov` screen
segments, torn-tail-safe PCM `.caf` audio segments, JSONL cursor/click chunks,
a hash-chained write-ahead journal, and an atomically replaced manifest.
`kill -9` at any moment loses at most the open segments; `aks recover` rebuilds
a valid project from committed data and never touches the original. Edits live
in `edits/timeline.json`; raw media is never modified.

`swift test` runs 422 tests: the automated forced-quit matrix, journal
fuzzing, recovery idempotency, deterministic spring/zoom fixtures
(seek == play-through), pixel-level composer checks, and export validation
including non-silence audio verification. Measured performance for the
styled pipeline is recorded in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).
`AKS_RUN_LONG_TESTS=1 swift test --filter TenMinuteGateTests` runs the
ten-minute 4K30 capture-integrity gate (passing), and
[`docs/MANUAL_TESTS.md`](docs/MANUAL_TESTS.md) covers real-capture procedures.
Since then: on-device captions with an editable transcript (SRT/VTT exact
through cuts/speeds/trim), camera PiP with a fullscreen intro scene,
per-clip speed with automatic dead-stretch detection, click ripples, an
opt-in keystroke shortcut overlay, spectral noise reduction at export,
looping GIF export, and a checkpointed RESUMABLE exporter (kill-safe
segments; re-exporting resumes). Neural audio enhancement (DeepFilterNet
class) remains open.
