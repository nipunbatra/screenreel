# Claude/Fable implementation contract for Aks

Build Aks from the specifications in `README.md` and `docs/`. These documents are normative. If a convenient shortcut conflicts with a safety invariant, the invariant wins.

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

## First task: Milestone 0 only

- create the Swift package/module skeleton and test targets;
- define versioned project and event schemas;
- implement atomic manifest writes and a write-ahead session journal;
- implement a project validator/recovery CLI;
- capture segmented raw screen and audio assets plus cursor/click events;
- add a synthetic ten-minute integration test and a manual forced-quit recovery test;
- leave the editor, motion engine, and denoiser behind interfaces/stubs.

Do not begin editor styling until the Milestone 0 gates in `docs/ACCEPTANCE_TESTS.md` pass.

## Suggested modules

```text
AksApp              SwiftUI/AppKit windows, permissions, commands
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
AksCLI              validate, recover, render, inspect
```

## Definition of done

- behavior is covered by a unit, fixture, or integration test;
- old projects remain readable or have a tested migration;
- errors are actionable in the UI and diagnostic log;
- no raw asset is mutated;
- documentation and fixtures are updated;
- `swift test` passes and media output is mechanically inspected.
