# ADR 0004 — Display-local event coordinates and the timingEstimated flag

- Status: accepted
- Date: 2026-08-24

## Context

Code review of the Milestone 0 implementation found that multiplying a global
Quartz point by the containing display's backing scale — without subtracting
the display origin — produces coordinates that are neither global-pixel nor
display-local on any display whose bounds do not start at the origin (every
secondary display, every mixed-DPI arrangement). "Global physical pixels" is
also not a well-defined space when displays have different backing scales.

Separately, recovery may attach a valid unjournaled tail segment whose time
range must be reconstructed (previous committed end + probed duration) rather
than measured; the spec requires "never assume" but the descriptor carried no
marker distinguishing reconstructed times from measured ones.

## Decision

1. **Event coordinates are display-local physical pixels**:
   `(globalPoint − displayBounds.origin) × backingScale`, stored together with
   the `displayID`. This is exact on every arrangement; conversion to captured
   source pixels uses the per-display geometry stored in the manifest
   `capture` block, exactly as before. `docs/PROJECT_FORMAT.md` §4 and the
   event-record schema `$comment` are updated accordingly.
2. **`SegmentDescriptor.timingEstimated: Bool?`** (additive, optional) is set
   `true` on any descriptor whose time range was reconstructed — today only
   recovery's orphan attachment, which also leaves `discontinuityBefore`
   unset (unknown) instead of asserting `false`. Later milestones must
   surface estimated timing in the editor before trusting it for sync.

## Consequences

- Schema v1 stays v1: both changes are additive/clarifying and old documents
  remain valid (`timingEstimated` absent means measured).
- Any future multi-display capture must record per-display bounds and scale
  in the `capture` block for the coordinate mapping to be reproducible.
