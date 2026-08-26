# ADR 0003 — Event chunk compression deferred behind a protocol

- Status: accepted
- Date: 2026-08-24

## Context

`docs/PROJECT_FORMAT.md` shows committed event chunks as `*.jsonl.zst` and says
to "chunk and zstd-compress only committed ranges". Apple's Compression
framework does not provide zstd, so honoring the extension today means adding a
third-party or vendored zstd dependency to the durability-critical write path
in Milestone 0.

## Decision

1. Milestone 0 commits event chunks as **plain `*.jsonl`** files using the same
   atomic `.partial` → fsync → rename → journal `eventChunkCommitted` protocol
   as media segments.
2. Compression sits behind an `EventChunkCompressor` protocol whose only
   Milestone 0 implementation is passthrough. Introducing zstd later changes
   the committed extension to `.jsonl.zst` without touching the commit
   protocol.
3. The validator, recovery, and `aks extract` accept both `.jsonl` and
   `.jsonl.zst` chunk names from day one, so projects written after the
   compressor lands remain readable by Milestone 0 readers only if
   uncompressed; readers therefore treat an unknown compressed chunk as an
   actionable "newer feature" error, never as corruption.

## Consequences

- Event data for a one-hour session is on the order of tens of MB uncompressed
  — acceptable while recovery guarantees are being proven.
- A future ADR must pick the zstd packaging (SwiftPM binary target, vendored C,
  or system library) before enabling compression, and add a schema fixture for
  compressed chunks.
