# Measured performance

Method and numbers behind the published claims. All measurements on the
development machine (Apple silicon MacBook Pro, macOS 15, release build of
the `aks` CLI), 2026-08-25, against a real 26.53 s lecture recording at
5120×2880 (5K Retina display capture, 30 fps, mic + system audio).

## Styled export (full pipeline: decode → compose → HEVC encode → mux)

```text
/usr/bin/time -l aks export <project> out.mp4 --styled --force
  14.6 s wall for 26.53 s of content  →  1.8× real time
  73 MB maximum resident set size
  795/795 frames validated by probe after mux
```

## Leaks

```text
leaks --atExit -- aks export <project> out.mp4 --styled --force
  Process …: 0 leaks for 0 total leaked bytes.
```

## Animated GIF export (same graph, palette container)

```text
aks export <project> out.gif --force
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
