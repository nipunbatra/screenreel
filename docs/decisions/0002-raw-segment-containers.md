# ADR 0002 — Raw segment containers and codecs

- Status: accepted
- Date: 2026-08-24

## Context

`docs/TECHNICAL_DESIGN.md` permits either fragmented MOV or short finalized MOV
segments for raw screen capture, and `docs/AUDIO_PIPELINE.md` mandates raw PCM
in CAF segments for v0.1 audio. The safety invariants require that every
committed segment be independently readable by ordinary tools and that a crash
lose at most the open segment.

## Decision

1. **Screen: short finalized QuickTime `.mov` segments, 4 seconds nominal.**
   Each segment is written to `<name>.partial` by its own `AVAssetWriter`,
   finalized, fsynced, checked by a basic decode inspection, renamed to its
   final name, and only then journaled as `segmentCommitted`. Fragmented MOV
   is not used for the raw asset in v0.1: finalized segments make "every
   committed file opens in QuickTime/ffprobe with no sidecar" trivially true,
   unlike fragmented-MP4 piles that need a finalization pass before they are readable.
2. **Screen codec: hardware HEVC by default at a visually lossless quality
   target, with H.264 available via configuration.** The codec, dimensions,
   and quality settings are recorded in the segment descriptor. Raw screen
   segments never include the cursor (`cursorBaked=false`); if a capture path
   cannot omit the cursor the track is labelled `cursorBaked=true`.
3. **Microphone and system audio: uncompressed PCM in CAF segments,
   48 kHz, device channel layout preserved,** rolled on the same nominal
   4-second boundary. CAF headers are valid even for truncated files, which
   keeps a torn tail partially readable.
4. **Segment duration is configuration, not constant** (`2...5 s` accepted
   range) so acceptance tests can exercise boundary behavior.

## Consequences

- A 4-second HEVC roll costs one keyframe per segment; for 4K30 slide content
  this is an acceptable size overhead in exchange for independent readability.
- Finalizing an `AVAssetWriter` every 4 seconds requires overlapping writers
  (open segment N+1 while N finalizes) to avoid dropping frames; the
  `VideoSegmentWriter` actor owns this handoff.
- Audio CAF at 48 kHz float32 mono is ~11.5 MB/min; acceptable for lecture
  lengths and always recoverable.
