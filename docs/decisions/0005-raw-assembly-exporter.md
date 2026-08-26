# ADR 0005 — Raw-assembly exporter ahead of the Milestone 3 export engine

- Status: accepted
- Date: 2026-08-24

## Context

The project owner needs Aks as a daily recorder immediately; the blocking gap
between "recording is safe" (Milestone 0) and "I can share a video" was the
exporter, which the roadmap schedules for Milestone 3 in its full segmented,
checkpointed, resumable form.

## Decision

Ship `aks export` now as a **raw assembly** step (`ExportEngine.SegmentAssembler`):

1. Video is **stream-copied** from the committed segments — no decode, no
   re-encode, no generation loss, ~20× real time. Sample times are shifted
   onto the project timeline; inter-segment gaps remain sparse (the previous
   frame persists), which is correct for screen content.
2. Microphone and system audio are mixed in float with a clip guard and
   AAC-encoded; gaps become explicit silence per `docs/AUDIO_PIPELINE.md` §8.
3. Export invariants from `CLAUDE.md` hold: raw media untouched, output
   written to `.partial` and renamed only after the file re-validates
   (decodable, sample counts match), failures leave any existing destination
   intact, damaged journals are refused with a recovery pointer.
4. The video and audio pumps run **concurrently**: a multi-input
   `AVAssetWriter` interleaves by timestamp and throttles each input until
   the others catch up, so sequential pumping deadlocks.

## Consequences

- This does not replace Milestone 3: checkpoint/resume, quality/size modes,
  frozen `RenderSnapshot` evaluation, and styled rendering still land there.
  `SegmentAssembler` becomes the "raw passthrough" path of that engine.
- Styled export (background/cursor/zoom rendering) re-encodes by necessity
  and builds on the same writer plumbing.
