# Bounded capture work and sample-aligned voice cleanup

Date: 2026-09-05

## Context

The owner reports system stalls during capture and soft recordings. Native
Retina sizing and NV12 capture already exist, but the screen handoff pins up
to six of eight compositor surfaces, the camera buffers sixteen frames, and
the writer does not explicitly rule out a software encoder. Keep native
pixels; reducing resolution is an explicit user choice.

The spectral reducer creates multiple arrays per 256-sample hop. Its export
integration feeds silence to “prime” it, which does not remove its fixed
512-sample delay. Voice cleanup must preserve both the first and last samples.

## Decision

- Share the capture surface budget between ScreenCaptureKit and the writer
  handoff: five compositor surfaces, two pending screen frames, with three
  surfaces reserved for delivery/encoding/compositing. Bound camera frames
  to three. Keep overflow visible in diagnostics.
- Attach consumers before calling each source's asynchronous `start`:
  ScreenCaptureKit can deliver frames before that call returns. Its shared
  stream starts only after handlers for every enabled audio/video track
  are registered. This avoids startup loss without enlarging the queues.
- Bound the real input-event handoff to 4096 records. Count discarded
  events in performance traces and journal a fault when the pump drains.
  Event callbacks never wait for storage or create one task per event.
- Require hardware H.264/HEVC encoding for live recording. Fail with an
  actionable error if unavailable instead of silently saturating the CPU.
  This does not change decoding of existing recordings or export policy.
- Keep the denoiser's FFT, overlap, input and output storage fixed-size.
  Left-pad the analysis window so the beginning of a take reconstructs
  correctly. Keep the public delay at 512 samples.
- Export consumes 512 samples of microphone lookahead and discards the
  actual delayed output once. Read zero padding beyond the export range,
  so the last 512 real samples survive without extending the export.
- Product display name is **Screen Reel**; the shell command, package
  extension, bundle identifier and existing storage paths remain stable
  (`screenreel`, `.screenreel`, including legacy `.aks` support).

No raw asset or project format is replaced. No extra dependency is needed.

## Validation

Use deterministic audio partition, onset/tail and noise attenuation tests;
synthetic segmented capture and media probes; and CLI compatibility tests.
Record before/after measurements in `docs/BENCHMARKS.md`.

Live ScreenCaptureKit and app/website checks resumed with the owner's
explicit permission after the lecture. Record the conditions alongside
results: a lower surface budget alone is not evidence of a measured
capture-speed gain. Keep the legacy v1 `.aks` fixture byte-for-byte and
require compatibility tests to read it, rather than skipping a renamed path.
