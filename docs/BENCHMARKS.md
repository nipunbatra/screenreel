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
