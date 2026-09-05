# Measured performance

## Voice cleanup microbenchmark (2026-09-05)

Before/after `swiftc -O` builds of `SpectralDenoiser.swift`, processing the
same seeded signal in 24,000-sample blocks, three runs of 60 s mono 48 kHz
audio. Run at nice level 15 on the owner's Mac during ordinary desktop use.
`Scripts/benchmark-denoiser.swift` contains the deterministic input and timer.

| Implementation | Run 1 | Run 2 | Run 3 | Median |
|---|---:|---:|---:|---:|
| Previous per-frame arrays/FIFO | 0.0784 s | 0.0612 s | 0.0614 s | 0.0614 s |
| Fixed buffers + vector/pointer copies | 0.0417 s | 0.0422 s | 0.0469 s | 0.0422 s |

About 31% less wall time in this microbenchmark. This is the reducer alone,
not full export, live recording CPU, or a perceptual speech-quality score.
The new version also adds the missing leading Hann overlap; sample values
therefore differ slightly from the old implementation at the head/warmup.
The onset/tail, block-partition and exported-audio alignment regression
tests pass, including a trimmed export.

The screen pool changes from eight to five NV12 surfaces. At 5120×2880,
three tightly packed NV12 frames represent about 63.3 MiB of pixel storage
(allocation padding and encoder memory are additional). This is a budget
calculation, **not measured RSS savings**. Preview's NV12 decode represents
1.5 bytes/pixel versus BGRA's 4; capture and whole-app effects need profiling.

## September 5 verification measurements

Release host: Apple M2 Max, 12 CPU cores, 64 GiB RAM, macOS 15.7.7.
Process CPU is relative to one core; the system figure averages all cores.

- Final suite: 521 tests, zero failures; two skips (the separately completed
  long export gate and intentional fixture regeneration). The real-recording
  golden comparisons passed with sampled pixel MAE 1.15–1.31.
- Long styled export: **30 minutes / 54,000 frames**, exact frame count,
  audio/video duration difference below 100 ms; 667.1 s encoding wall time
  (81.0 fps) at 180p, 515 MB peak test-process RSS. Generating the input
  fixture took additional time. This is a longevity check, not a 4K benchmark.
- Signed app on a copy of a real legacy `.aks` recording: editor playback,
  restyle and export passed. Export was **5120×2880 HEVC at 30 fps**, 212
  frames, 48 kHz mono AAC, 7.067 s video versus 7.033 s audio. All four raw
  file hashes still match the original project.
- Menus, hotkeys, countdown, area selection and window hiding/restoration
  passed the native UX harness. Playback presented Metal drawables with no
  nil-drawable events in the measured interval.
- Initial real CLI screen-only capture: **4096×2304 at 30 fps**, 8.4 s,
  average CPU 3.84%, peak 6.67%, peak RSS 58.6 MiB, zero dropped frames or
  buffers. This excludes microphone, events and the app UI.
- A subsequent real 30 s microphone capture exposed 13 startup buffer
  drops, all present in its first performance sample and unchanged later.
  Inspection found consumers were attached after asynchronous source start,
  and shared capture began before every enabled track had a handler. The
  startup follow-up fixes these orderings and adds a deterministic regression.
- After the startup fix, a **30 s real 4096×2304/30 fps capture with
  microphone and event capture enabled** recorded 901 video frames and
  1,451,008 microphone samples with **zero dropped frames/buffers**.
  Peak RSS was about 69 MiB; average process CPU was about 13%, peak 16%.
  CPU workload/content differed between trials; these short traces do not
  establish a before/after CPU speedup. No clicks occurred in this interval,
  so the healthy validator reported the empty click track as a warning.
- The earlier ten-minute 4K30 synthetic gate lost one handoff buffer
  (17,999/18,000 frames). The final startup-fixed build passed with
  **18,000/18,000 frames and zero dropped frames/buffers**, 150 independently
  readable segments and exact microphone sample counts. Mean process CPU
  69%, peak 83%; peak test-process RSS 970 MiB after the full suite. This
  synthetic 2×-paced BGRA generator differs substantially from live NV12
  capture; these numbers must not be presented as GUI capture overhead.

Live CLI capture is available through the development environment's
existing Screen Recording access. The signed GUI app's independent access
is off and System Settings requires the owner's password to enable it.
No password or new signing credential was requested or stored.

## Earlier measurements

Method and numbers behind the published claims. All measurements on the
development machine (Apple silicon MacBook Pro, macOS 15, release build of
the `screenreel` CLI), 2026-08-25, against a real 26.53 s lecture recording at
5120×2880 (5K Retina display capture, 30 fps, mic + system audio).

## Styled export (full pipeline: decode → compose → HEVC encode → mux)

```text
/usr/bin/time -l screenreel export <project> out.mp4 --styled --force
  14.6 s wall for 26.53 s of content  →  1.8× real time
  73 MB maximum resident set size
  795/795 frames validated by probe after mux
```

## Leaks

```text
leaks --atExit -- screenreel export <project> out.mp4 --styled --force
  Process …: 0 leaks for 0 total leaked bytes.
```

## Animated GIF export (same graph, palette container)

```text
screenreel export <project> out.gif --force
  530 frames at 960×540 (20 fps), 7.1 MB, 6.9 s wall  →  3.8× real time
```

## Repro notes

- The recording used is a private lecture capture; any ~30 s 5K display
  recording reproduces the shape of these numbers.
- Numbers vary with content complexity and machine load; the acceptance
  floor in `docs/ACCEPTANCE_TESTS.md` (≥0.5× real time at 4K30) is the
  gate, these figures are the measured headroom.
- In-app export adds editor/preview overhead on top of the CLI figures.

## Editor interaction latency (2026-08-26)

Method: `PerfSmokeTests` on a synthetic 60 s 320×180 project, release-mode
engines, machine under normal desktop load (load avg ~20).

| Measure | Result |
|---|---|
| Editor open (composition construction) | 76 ms |
| First frame rendered (1280×720) | 98 ms |
| Scrub storm, 40 random seeks | 25.8 ms/frame |

The start screen requests display previews only on real events (open,
source change, app activation) — zero standing WindowServer traffic —
and rapid scrubs render at half resolution, settling to full quality
350 ms after the last seek.

## Waveform loading and editor work (0.2.1, 2026-09-05)

Same M2 Max host. `swiftc -O` builds of the old and new `AudioWaveform.swift`,
processing the identical generated 120 s stereo float32 CAF at 48 kHz into
400 buckets. One untimed warmup and five timed runs; the file is cached by
the OS. `Scripts/benchmark-waveform.swift` creates and verifies the signal.
No physical audio device is involved.

| Implementation | Five timed runs (seconds) | Median |
| --- | --- | --- |
| Scalar sample scan / fixed 1024-frame groups | .019015, .018284, .018211, .017601, .017329 | .018211 s |
| vDSP peak scan / exact bucket boundaries | .007578, .008127, .007588, .007086, .006734 | .007578 s |

**58.4% less waveform calculation wall time** in this microbenchmark. This
is not a whole-app CPU reduction or a measured editor-open speedup. The
vector path also fixes short-recording bucket placement, caps reads to the
committed range/timeline, and observes cancellation between 48,000-frame
reads. Closing or switching editors cancels both loading and waveform tasks.

The placeholder now uses only an existing thumbnail cache. A cache miss
starts no second composition or video decoder; tests assert that it creates
no cache directory/failure marker and leaves corrupt cached files untouched.

Final focused editor smoke: construction 63 ms, first decoded frame 5 ms,
40 spread-out seeks 14.6 ms/frame on the existing synthetic 60 s 320×180
fixture. This is a coarse regression check under current desktop load,
not a controlled before/after comparison.

Logs: `.build/gallery-checks/waveform-{before,after}.txt`,
`waveform-tests.log`, `full-tests.log`, and `final-focused-tests.log`.
The full suite passed 533 checks (three skips: both long opt-in gates and
fixture regeneration); the final 18-test focused run includes the two new
cache tests. Together these cover 535 distinct Swift checks with three
intentional skips. The prior 0.2.0 ten-minute 4K and thirty-minute export
measurements above remain separate evidence; they were not re-measured for
this waveform/thumbnail change.

## Actual window capture and music (0.3.0, 2026-09-05)

Production ScreenCaptureKit window capture of the purpose-made animated Wave
Lab Mac app, 1920×1148 native Retina pixels, nominal 30 fps, HEVC. These are
short observations under normal desktop load, not a controlled comparison
against another recorder or a long-duration stability claim.

| Capture | Duration | Process CPU, mean / peak | Peak RSS | Committed screen frames | Handoff drops |
| --- | --- | --- | --- | --- | --- |
| Silent window, no events | 13.44 s | 5.09% / 8.37% | 42.3 MiB | 381 | 0 |
| Window with system audio | 24.65 s | 12.92% / 17.32% | 57.7 MiB | 494 | 0 |

Both projects validated without errors; the system-audio take has an empty
cursor event-track warning because accessibility button actions do not emit
physical input events. Its audio remains local. ScreenCaptureKit can omit
unchanged frames, so delivered frame counts are not a constant-rate target.

An idle silent screen previously ended at its last delivered frame. The fix
extends the final container session to Stop with `AVAssetWriter.endSession`.
A regression stores one frame for ten seconds and decodes it at the beginning,
middle and end, checking both container and manifest duration. Retaining an
SCK sample for a stop-time append was tried and rejected: it starved the live
surface pool. The final implementation retains no extra capture surface and
does not re-encode duplicates. See decision 0011.

Music import converts in bounded blocks off the UI thread. Export reuses one
24,000-frame stereo PCM buffer and an open file regardless of song length;
normal and checkpointed exports share the same mixer. Preview plays the
portable working file. This release does not claim a measured whole-app
speedup from adding music.

In the published controlled speech-plus-hiss fixture, RMS over the final
three seconds of noise falls from −32.10 to −52.12 dBFS after cleanup (20.02 dB).
The speech interval from 2–6 s changes from −15.25 to −16.22 dBFS. Noise
estimation adapts over time, so the first half-second has little attenuation.
These measurements describe this fixture, not all microphones or noise types.
The reusable-buffer denoiser speed measurement from 0.2.0 remains above.

Local evidence: `.build/gallery-checks/public-media-030.json`,
`.build/real-gallery/*/diagnostics/perf-summary.json`, and
`.build/gallery-checks/release-final-tests-030.log`.
