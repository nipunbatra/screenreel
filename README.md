# Screen Reel

**Record clearly. Make it yours.** A native Mac screen recorder with editable zooms, cursor motion, captions, camera layouts, and local voice cleanup.

Screen Reel keeps the original screen, voice, system audio, camera, and cursor data separate. A project is an open folder of standard media and readable metadata. No account or cloud service is needed. The code is MIT licensed.

The app builds as **Screen Reel.app**; its command is **`screenreel`**. The bundle ID (`com.nipunbatra.screenreel`), `.screenreel` project extension, and `~/Movies/Screenreel` storage location stay stable. Legacy `.aks` packages remain readable, and the existing migration from `~/Movies/Aks` is preserved.

[Website](https://nipunbatra.github.io/screenreel/) · [Project format](docs/PROJECT_FORMAT.md) · [Build and sign](docs/DISTRIBUTION.md) · [Current improvement checkpoint](docs/IMPROVEMENT_HANDOFF.md)

## Product promise

1. **Safe before stylish.** Screen, microphone, system audio, camera, cursor events, clicks, and metadata are persisted as separate recoverable assets while recording.
2. **Polish stays editable.** Cursor smoothing, click effects, zooms, backgrounds, padding, corners, shadows, masks, and captions are non-destructive project data.
3. **Fast preview, dependable export.** Editing uses proxies and reduced effects. Final export is deterministic, hardware accelerated, checkpointed, cancellable, and resumable.
4. **The project is open.** A project is a documented folder/package. Even if Screen Reel will not launch, the raw media can be opened with ordinary tools.

## Features

Screen Reel is built for local recording and editing on macOS:

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

## Privacy

Screen Reel needs no account and sends no telemetry. Recordings, transcripts,
captions, and exports are produced and stay on your Mac. License keys are
verified offline with a public key embedded in the app.

The app makes exactly **one** kind of network request: the update check. It
is a single GET to `https://api.github.com/repos/nipunbatra/screenreel/releases/latest`
that runs when you choose *Check for Updates…* and, if *Check for Updates
Automatically* is on (the default), at most once every 24 hours. It carries
no identifiers beyond a `User-Agent` of `Screenreel/<version>`; GitHub sees
your IP address as with any web request. Turn it off in the app menu (stored
as `updates.automatic` in the app's preferences). Nothing else in the app or
the `screenreel` CLI opens a connection.

## Download and distribution

[Download Screen Reel 0.3.0](https://github.com/nipunbatra/screenreel/releases/latest/download/screenreel.dmg)
for **Apple silicon, macOS 15+**. The installer is Developer ID signed,
notarized by Apple, and stapled for Gatekeeper. Release notes and SHA-256
checksums are on [GitHub Releases](https://github.com/nipunbatra/screenreel/releases).
See the [screenshots and demos](https://nipunbatra.github.io/screenreel/#gallery).
The version of record is the `VERSION` file. Building, signing, notarizing,
releasing, and issuing license keys are described in
[`docs/DISTRIBUTION.md`](docs/DISTRIBUTION.md). Licenses gate nothing today —
the mechanism exists ahead of any pricing decision.

## Build the app (macOS 15+, Swift 6)

See [`docs/decisions/`](docs/decisions/) for the architecture decisions.

**The app** (recorder + editor):

```bash
Scripts/make-app.sh             # builds dist/Screen Reel.app (version from VERSION)
open "dist/Screen Reel.app"      # grant Screen Recording, Microphone, Input Monitoring
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

## Screenshots and background music

In the start screen, select **Screen**, **Window**, **Area** or **App**, then
choose **Save Screenshot** (⇧⌘S). Screen Reel saves a PNG at the selected
capture resolution and does not start microphone or webcam recording.

In the editor’s **Audio** inspector, choose **Add Music…**. Import MP3, M4A,
WAV or AIFF, adjust the music volume, and choose whether it loops. Music plays
in the preview and in normal or resumable styled exports. Turn off **Include
audio** for a silent export. Microphone noise reduction applies at export;
raw capture audio and imported originals stay unchanged.

Imported music is copied into `assets/music/` inside the project, alongside
a 48 kHz stereo CAF working copy. Moving the project keeps its music. Removing
the music clears the edit reference and preserves its assets for undo.

## CLI

```bash
swift build -c release --product screenreel --jobs 2
.build/release/screenreel env                       # environment + capturable displays
.build/release/screenreel sources                   # display/window/app/camera IDs
.build/release/screenreel record                    # real capture until Ctrl-C
.build/release/screenreel record --window 123 --no-mic
.build/release/screenreel record --app com.apple.Safari --system-audio
.build/release/screenreel record --area 100,100,800,500 --camera
.build/release/screenreel screenshot window.png --window 123
.build/release/screenreel music <project.screenreel> --file song.mp3 --volume 0.2
.build/release/screenreel music <project.screenreel> --no-loop
.build/release/screenreel music <project.screenreel> --remove
.build/release/screenreel record --synthetic --duration 30 --pace 1   # no permissions needed
.build/release/screenreel export    <project.screenreel>            # raw assembly to MP4
.build/release/screenreel export    <project.screenreel> --styled   # edits rendered in
.build/release/screenreel validate  <project.screenreel>   # checksums, journal chain, decode probes
.build/release/screenreel recover   <project.screenreel>   # crash recovery to a fresh copy
.build/release/screenreel extract   <project.screenreel> <dir>   # raw media + events.csv/json
.build/release/screenreel inspect   <project.screenreel> --journal
.build/release/screenreel perf      <project.screenreel> --trace   # CPU/system load/drops per second
```

If a recording felt laggy, `screenreel perf` answers why from the project itself:
every session keeps a per-second trace of the app's CPU next to the whole
machine's, plus frame drops and cursor-tap latency (`diagnostics/perf.jsonl`).

A recording is a `.screenreel` package: 4-second finalized HEVC/H.264 `.mov` screen
segments, torn-tail-safe PCM `.caf` audio segments, JSONL cursor/click chunks,
a hash-chained write-ahead journal, and an atomically replaced manifest.
`kill -9` at any moment loses at most the open segments; `screenreel recover` rebuilds
a valid project from committed data and never touches the original. Edits live
in `edits/timeline.json`; raw media is never modified.

`swift test --jobs 1` runs the automated forced-quit matrix, journal
fuzzing, recovery idempotency, deterministic spring/zoom fixtures
(seek == play-through), pixel-level composer checks, and export validation
including non-silence audio verification. Measured performance for the
styled pipeline is recorded in [`docs/BENCHMARKS.md`](docs/BENCHMARKS.md).
`SCREENREEL_RUN_LONG_TESTS=1 swift test --filter TenMinuteGateTests` runs the
ten-minute 4K30 capture-integrity gate, and
[`docs/MANUAL_TESTS.md`](docs/MANUAL_TESTS.md) covers real-capture procedures.
Since then: on-device captions with an editable transcript (SRT/VTT exact
through cuts/speeds/trim), camera PiP with a fullscreen intro scene,
per-clip speed with automatic dead-stretch detection, click ripples, an
opt-in keystroke shortcut overlay, spectral noise reduction at export,
looping GIF export, and a checkpointed RESUMABLE exporter (kill-safe
segments; re-exporting resumes). Neural audio enhancement (DeepFilterNet
class) remains open.
