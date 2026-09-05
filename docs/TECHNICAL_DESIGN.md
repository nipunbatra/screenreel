# Technical design

## 1. Architecture decision

Build a native macOS application in Swift with explicit media-engine packages. This gives direct access to ScreenCaptureKit, Core Audio, Metal, AVFoundation, and VideoToolbox; predictable permissions; low idle overhead; and a realistic path to long 4K captures.

Use actors for ownership of long-lived media state. Avoid funneling sample buffers through `@MainActor`. UI state observes immutable snapshots from engine actors.

## 2. Layer map

```text
ScreenreelApp
  ├── CaptureCoordinator ── ScreenCaptureKit / Core Audio / Event Tap
  │     └── ProjectWriter ── segment files + journal + manifest
  ├── EditorModel ───────── TimelineCore + ProjectModel
  │     ├── PreviewEngine ─ RenderGraph evaluator (Metal)
  │     ├── AudioPipeline ─ raw/enhanced/cache/waveform
  │     └── MotionEngine ── cursor + click + zoom evaluator
  ├── ExportCoordinator ─── frame scheduler + VideoToolbox + mux/checkpoints
  └── Diagnostics ───────── validator + recovery + structured logs
```

## 3. Capture pipeline

### Shared clock

At session start, record a clock anchor containing `mach_continuous_time`, numer/denom timebase, UTC wall time, and first timestamp observed from each stream. Convert every event/sample to signed nanoseconds relative to the monotonic session origin.

Do not subtract audio and video timestamps produced by unrelated clocks without an explicit mapping. Preserve each source timestamp and the normalized timeline timestamp for diagnosis.

### Screen and system audio

- ScreenCaptureKit `SCStream` with outputs for `.screen` and `.audio` where available.
- Capture at the physical pixel dimensions selected by the user, capped only by an explicit setting.
- Prefer 30 fps for lectures and allow 60 fps; variable source cadence is represented with timestamps.
- `queueDepth` is small and monitored. Sample handling copies/enqueues minimal data and returns immediately.
- Write 2–5 second independently readable segments. Fragmented MOV is acceptable if AVFoundation proves reliable; otherwise use short finalized MOV segments with a manifest.
- The raw screen defaults to no cursor. If an OS/configuration cannot omit it, label the track `cursorBaked=true` and disable replacement cursor by default.

### Microphone

- Capture uncompressed or lightly compressed 48 kHz audio in independent segments.
- Keep the actual device channel count and channel layout; derive mono later.
- Record device UID, nominal/actual sample rate, buffer size, discontinuities, overruns, and route changes.
- If a device misreports its format, fail before recording or switch through an explicit converter; never reinterpret bytes under the wrong ASBD.

### Cursor/click/keyboard events

- Accessibility/event-tap permission is requested separately from screen recording.
- Capture position in global display pixels, button state, event type, modifiers, pressure when available, monotonic time, cursor descriptor ID, and the active display mapping.
- Snapshot a cursor descriptor on change: original PNG/PDF representation when legally/system available, size, scale, and hotspot. The project may also store a semantic name for an original Screenreel vector substitute.
- Keyboard capture is opt-in, visibly indicated, and filters password/secure-input contexts. Raw text is not captured during secure input.

### Durable writes

1. Create project directory and `session.lock`.
2. Write manifest atomically (`tmp`, fsync, rename).
3. Append journal records with checksum and monotonic sequence.
4. Finalize each segment; fsync media and directory; then journal `segmentCommitted`.
5. Checkpoint events in chunks and atomically update indexes.
6. On stop, close streams, commit tail segments, update duration, validate, and only then clear the incomplete-session marker.

## 4. Editor and timeline

The timeline maps project time to a source asset and source time:

```text
ProjectTime → Clip → SourceTimeMapping → Raw Asset
```

Cuts, speed changes, audio offsets, and gaps are immutable edit records. Use an undoable command log or persistent value model; autosave a compact current manifest plus optional undo history.

Audio, cursor events, zoom events, masks, text, captions, and camera scenes live in independent lanes. Their time ranges are transformed when a clip is split or speed-adjusted using explicit policies and tests.

## 5. Render graph

At time `t`, evaluate:

1. source clip and source time;
2. screen crop and base transform;
3. active zoom camera transform;
4. background, screen shadow/border/corners, and screen texture;
5. screen-anchored masks/highlights/annotations;
6. cursor state under the same camera transform;
7. camera layout and scene transition;
8. canvas-anchored text/captions/overlays;
9. output color conversion.

Represent the result as immutable render commands. Preview and export use the same evaluator and shader/library versions. Preview may use proxy textures, reduced motion blur samples, or a smaller render target.

## 6. Preview

- Generate an intraframe-friendly 1080p or half-resolution proxy in the background.
- Fall back immediately to raw media; proxy availability is per segment.
- Use `MTKView`/Metal and audio-clock-driven playback.
- Cache decoded frames around the playhead and invalidate only affected graph nodes.
- Quality modes: Accurate, Responsive, Power Saving. Accurate must match export within the pixel tolerances in `ACCEPTANCE_TESTS.md`.

## 7. Audio pipeline boundary

Audio enhancement is a job keyed by raw asset checksum + algorithm/model version + settings. The editor receives a derived audio asset and a time mapping; it does not invoke a denoiser in the render callback. See `AUDIO_PIPELINE.md`.

## 8. Export boundary

The exporter consumes a frozen `RenderSnapshot` containing project schema version, asset checksums, settings, model versions, frame-rate policy, and range. It cannot observe live editor mutation. New edits create a new snapshot/job. See `EXPORT_PIPELINE.md`.

## 9. Package/API sketch

```swift
public protocol ProjectStore: Sendable {
    func create(at url: URL, capture: CaptureConfiguration) async throws -> ProjectID
    func append(_ record: JournalRecord) async throws
    func commit(_ segment: SegmentDescriptor) async throws
    func load(at url: URL) async throws -> ProjectSnapshot
    func validate(at url: URL) async -> ValidationReport
}

public protocol CompositionEvaluator: Sendable {
    func commands(at time: TimelineTime, in snapshot: RenderSnapshot) throws -> RenderCommands
}

public protocol Exporting: Sendable {
    func start(_ job: ExportJob) async throws -> AsyncThrowingStream<ExportProgress, Error>
    func resume(jobID: UUID) async throws -> AsyncThrowingStream<ExportProgress, Error>
}
```

No package should import SwiftUI except `ScreenreelApp` and preview UI adapters.

## 10. Diagnostics and observability

- Structured JSONL logs per session/export with monotonic and wall times.
- Signposts for capture queues, drops, decoder latency, render latency, encode latency, segment commits, and disk throughput.
- A user-facing diagnostic report lists app/OS/hardware versions, source formats, segment health, free space, dropped frames, A/V discontinuities, enhancement/export job state, and redacted paths.
- Never include microphone content, frame pixels, typed keys, or unrelated filenames in diagnostics by default.
- **Performance trace.** Every recording writes `diagnostics/perf.jsonl` — one sample per heartbeat (1 s) with this process's CPU (100 = one core), whole-machine CPU, RSS, thermal state, load average, writer frame/drop counters, and the cursor event tap's callback latency and re-enable count — and `diagnostics/perf-summary.json`, an interval-weighted digest with operator-facing concerns (drops, tap stalls, thermal throttling, CPU saturation). `screenreel perf <project> [--trace]` prints it; the app keeps the digest after a stop. The event tap matters here because a listen-only `CGEventTap` still sits in WindowServer's delivery path: a slow or starved callback lags every app's input, and a timed-out tap is silently disabled by macOS — the tap thread runs at user-interactive QoS and re-enables itself.
- **Activity assertions.** The coordinator holds a `ProcessInfo` activity (no App Nap, no idle system or display sleep, latency-critical) for the whole recording — the app hides its window while recording, which otherwise makes it nap-eligible — and every exporter holds one for the duration of the job.

## 11. Security and privacy

- Local operation is the default and requires no account.
- Secure-input awareness for keyboard capture.
- Project packages inherit normal user permissions; no world-readable temp media.
- Custom model downloads require checksums/signatures and a clearly displayed source/license.
- No telemetry in v0.1. If introduced later, opt-in separately from crash diagnostics.

## 12. Performance targets

- Capture actor p99 handling under 5 ms with zero blocking filesystem work on the SCStream callback queue.
- Preview seeks produce a visible frame within 150 ms on proxy and 400 ms on raw media.
- Accurate preview sustains 30 fps for a 4K slide capture at 50% display scale on the target Apple Silicon baseline.
- Working-set memory stays bounded by caches; a one-hour recording must not create a one-hour in-memory event array.


## Platform and open-source references

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [Apple AVFoundation](https://developer.apple.com/av-foundation/)
- [Apple VideoToolbox](https://developer.apple.com/documentation/videotoolbox)
- [Apple Metal](https://developer.apple.com/metal/)
- [DeepFilterNet](https://github.com/Rikorose/DeepFilterNet) — local speech enhancement; verify model/code licenses and notices before packaging
- [FFmpeg filters documentation](https://ffmpeg.org/ffmpeg-filters.html) — reference for `speechnorm` behavior and test tooling
