# Known issues and accepted trade-offs

Tracked consciously; none violate the safety invariants. Date: 2026-08-25.

- **Rapid clip-op bursts** (PreviewPlayer.applyClips): two clip operations
  issued in the same runloop burst could clobber each other because each
  computes the new clip array from the main-actor `edits` copy before the
  first round-trips through the composition box. User gestures cannot
  realistically fire that fast; revisit if clip ops ever become scriptable.
- **Transcriber watchdog relies on SFSpeech cancel semantics**: the
  per-segment timeout (4× duration, min 2 min) cancels the recognition
  task and unwinds via its error callback. If a pathological recognizer
  ignored cancel entirely, the group would still wait on that callback;
  Apple's implementation reliably errors on cancel.
- **Command palette row identity churns** per body evaluation
  (`PaletteCommand.id = UUID()`); selection is index-based so behavior is
  correct, but rows re-identify if the sheet re-evaluates while open.
- **`ClipTimeline.outputTime(forSource:)` boundary rounding**: the last
  source sample of a sped clip can map to the next clip's exact output
  start. Documented at the declaration; all current callers absorb it.
- **Sped clips near a denoised boundary**: the block containing a
  speed transition disables noise-floor learning for the whole block
  (~21 ms) — conservative by design, inaudible.
- **Some integration tests assume synthetic recording succeeds**: under a
  broken/sandboxed AVFoundation (observed in a Codex verification sandbox,
  errors -11800/-12903), `CLISurfaceTests.testExportFailsNamingMissingMiddleSegment`
  force-indexes `segments[1]` and crashes instead of failing with a message.
  Harmless on real hardware; guard with XCTSkip when the fixture reports
  zero segments if CI ever runs sandboxed.
- **Preview audio paces by the CAF header rate**: on a recording where a
  device rate-lie was detected (descriptor carries the observed rate, the
  header keeps the declared one), preview audio is paced by the header —
  off by the lie ratio — while export refuses loudly instead. Rare device
  fault; preview stays usable, export stays honest.
- **Play-before-prepare window**: pressing play in the first instants after
  opening a project (before the audio actor finishes preparing) yields one
  silent playback session; the next pause/play is normal.
- **Checkpointed-export job retention**: superseded job directories
  (settings changed mid-job) are never garbage-collected; the spec defers
  retention cleanup, so an abandoned different-settings job can hold disk
  until manually removed from the project's jobs/ directory.
- **First-segment disk guess**: with no rendered segment yet, the disk
  preflight assumes 512 MB per segment × 1.25 — a tiny multi-segment
  export on a nearly-full disk can be refused conservatively. Assembly has
  no separate preflight; its failure path is clean (partial removed, job
  preserved).
- **Unmapped keycodes** (keypad, ISO/JIS extras) render as literal
  "keyNN" chips when pressed with a chording modifier.
