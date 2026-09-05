# Claude/Fable implementation contract for Screenreel

Build Screenreel from the specifications in `README.md` and `docs/`. These documents are normative. If a convenient shortcut conflicts with a safety invariant, the invariant wins.

## Non-negotiable invariants

- Never make the only copy of a recording a single MP4 that must be finalized to be readable.
- Never bake cursor, camera, microphone, system audio, zooms, or effects into the sole raw screen asset.
- Never overwrite or delete raw media during enhancement, editing, proxy generation, or export.
- Write metadata atomically and make every operation longer than five seconds restartable or safely repeatable.
- Use one monotonic host clock for all streams and store the mapping required to reproduce presentation times.
- Preview and export evaluate the same composition graph. Quality may differ; geometry, timing, and event evaluation may not.
- A cancelled or failed export leaves the project valid and reports the exact stage, asset, error, and recovery action.
- Do not use any other product's proprietary code, cursor art, wallpapers, models, names, or trademarks.
- Do not copy code from AGPL-licensed screen recorders without an explicit compatible licensing decision.

## Working method

1. Read `docs/ROADMAP.md`; implement one milestone at a time.
2. Before changing architecture or the project schema, add an ADR under `docs/decisions/NNNN-title.md`.
3. Use small Swift packages with protocol boundaries, not a monolithic app target.
4. Add deterministic fixture projects before building editor controls.
5. Run narrow package tests, then the milestone's media/acceptance tests.
6. Never close a capture/export issue from UI behavior alone. Inspect output with `ffprobe`, validate timestamps, and compare expected frame/audio counts.
7. Keep commits small and label incomplete behavior clearly. Do not hide a missing feature behind a non-functional control.

## Current state (2026-09-05)

Milestones 0–4 are implemented: durable segmented recorder, editor with
Metal preview, motion engine, captions, camera, styled/raw/GIF and
checkpointed export, menu bar + global hotkeys + area picker, licensing and
release scripts. The project was renamed from "aks" to Screenreel; old
`.aks` packages and the `in.aks.project` format id stay readable forever
(`ProjectSchema`), and `~/Movies/Aks` migrates to `~/Movies/Screenreel`.

Working rules that were learned the hard way:

- Never replace `dist/Screenreel.app` with an unsigned build: an ad-hoc
  signature invalidates every permission grant. `Scripts/make-app.sh`
  refuses to swap in a bundle when Developer ID signing fails; use
  `ALLOW_ADHOC=1 Scripts/make-app.sh dist-test` for throwaway bundles.
- Harnesses: `SCREENREEL_AUTOPILOT_DIR=<dir>` drives start → editor → play →
  restyle → export on a COPY of `SCREENREEL_AUTOPILOT_PROJECT` and writes
  `report.txt` (result=PASS) plus window snapshots; `SCREENREEL_UX_SELFTEST_DIR`
  exercises menus, panels, hotkeys and the area picker. Harness launches never
  touch ScreenCaptureKit or the microphone (no permission prompts). Kill only
  the PID you launched — several sessions run the same binary name.
- Screen Recording permission is never available to processes launched from
  developer tooling; real capture is verified by the owner per
  `docs/MANUAL_TESTS.md`. Every recording writes `diagnostics/perf.jsonl`
  and `perf-summary.json`; `screenreel perf <project> --trace` reads them.
- One `swift build`/`swift test` per checkout at a time; agents work in
  their own worktrees. Long gates: `SCREENREEL_RUN_LONG_TESTS=1 swift test
  --filter TenMinuteGateTests` (fails under heavy machine load by design).
- Performance is a feature: measure before and after (CPU, RSS, GPU,
  WindowServer, frames rendered), record numbers in `docs/BENCHMARKS.md`,
  and add a regression test for every win.

## Suggested modules

```text
ScreenreelApp              SwiftUI/AppKit windows, permissions, commands
CaptureCore         ScreenCaptureKit coordination and shared clocks
ProjectModel        schemas, atomic persistence, validation, migration
EventCapture        cursor/click/keyboard events and cursor descriptors
TimelineCore        clips, trims, time mapping, undo/redo model
MotionEngine        auto zooms, springs, cursor evaluation
AudioPipeline       enhancement jobs, cache, loudness and sync checks
RenderGraph         deterministic composition graph
PreviewEngine       Metal-backed interactive evaluation
ExportEngine        segmented/checkpointed VideoToolbox encode and mux
Diagnostics         logs, environment report, project/media validation
ScreenreelCLI              validate, recover, render, inspect
```

## Definition of done

- behavior is covered by a unit, fixture, or integration test;
- old projects remain readable or have a tested migration;
- errors are actionable in the UI and diagnostic log;
- no raw asset is mutated;
- documentation and fixtures are updated;
- `swift test` passes and media output is mechanically inspected.
