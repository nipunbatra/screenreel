# Preview and export pipeline

## 1. Requirements

Export must be deterministic, bounded in memory, transparent about progress, safe to cancel, and resumable after process failure. A finished file is reported only after mechanical validation.

## 2. Frozen job

Starting an export creates `jobs/export-<uuid>/job.json` with:

- immutable render snapshot and project generation;
- raw/derived asset checksums;
- output range, dimensions, frame-rate policy, color space;
- codec/profile/bitrate or quality/target-size settings;
- audio graph and model/algorithm versions;
- render engine/shader version;
- destination and temporary paths;
- estimated frame count, byte size, working space, and segment plan.

Edits made after start do not affect that job.

## 3. Proof export

Proof export is a first-class workflow, not a separate approximate renderer:

- default range is 20 seconds around the playhead;
- it evaluates the same render snapshot, frame timestamps, audio graph, cursor hotspots, and zoom springs;
- it may use hardware H.264 and a lower bitrate, but output dimensions can remain 4K when checking slide legibility;
- its validation report is visible and can be attached to a later full job.

## 4. Frame scheduling

For constant frame rate `fps`, frame `n` is evaluated at exact rational time `n/fps` within the selected range. Avoid repeated floating-point additions. Source selection/decoding uses timestamps; duplicate/drop policy is explicit when source cadence differs.

Determine frame count from range and rational frame duration. Progress numerator is committed encoded frames, not requested frames or wall-clock guesses.

## 5. Segmented render

Split at deterministic 30–120 second boundaries aligned to output keyframes; prefer timeline-safe boundaries and never split inside a transition that depends on unavailable temporal samples.

For each output segment:

1. Decode required raw/proxy frames and audio.
2. Evaluate render commands and render frames through Metal.
3. Encode an independently readable video segment with VideoToolbox.
4. Render/mix the matching audio range or keep a deterministic continuous audio plan.
5. Flush/finalize; run quick decode/timestamp checks.
6. Atomically rename the segment and checkpoint its checksum/frame range.

On retry, reuse a segment only when all input/checksum/settings/engine keys match. A damaged segment is re-rendered in isolation.

## 6. Final assembly

- Concatenate compatible segments without re-encoding when possible.
- Mux the final audio and video with normalized start time zero and explicit edit list only if required.
- Write to a destination sibling `.partial`; never overwrite an existing output without the user's explicit file-panel choice.
- Validate `.partial`; only then atomically rename to the final filename.
- Preserve the export job/checkpoints until the user dismisses success or retention cleanup runs later.

## 7. Hardware encode

Use VideoToolbox and verify that a hardware encoder was actually created when requested. Offer:

- H.264 High Profile for widest compatibility;
- HEVC Main/Main10 when source/output and user preference justify it;
- 4:2:0 8-bit SDR first; define color/HDR behavior before enabling HDR.

Do not encode 4K frames through a software fallback silently. If hardware setup fails, explain the fallback speed/compatibility and let the user choose.

## 8. Quality and size

Three modes:

- **Quality:** quality factor/bitrate tuned to content; estimated size shown.
- **Target size:** derive a video budget after audio/container allowance; warn that exact size is not guaranteed with single-pass hardware encode.
- **Advanced:** codec/profile, average/max bitrate, GOP, frame rate, and optional multi-pass/software path.

For slide/math video, preserve full resolution and trade frame rate/bitrate before downscaling. A starting 4K30 H.264 range of 8–12 Mb/s is reasonable for mostly static content; fast motion fixtures tune adaptive ceilings.

## 9. Progress and ETA

Progress stages and weights derive from real work:

```text
Preparing assets
Enhancing audio (if uncached)
Rendering segment i/n — frame x/y
Assembling
Validating video/audio
Finalizing destination
```

Persist last durable progress time. If no segment/frame/checkpoint advances for 30 seconds, mark the job `attentionNeeded`, capture queue/encoder/disk diagnostics, and offer retry/cancel/open-log. Never display a frozen percentage indefinitely.

ETA uses an exponentially weighted rate from completed frames after warm-up and reports a range when variance is high.

## 10. Disk safety

Before start, estimate:

```text
final output + temporary segments + decoded/audio work + safety margin
```

Require at least 1.25× the estimate and recommend 2.5× final output plus cache for long 4K jobs. Recheck space at segment boundaries. Low space pauses safely before starting another segment; it does not corrupt committed work.

## 11. Cancellation and resume

- Cancel stops scheduling, asks active encoders to finish/abort, removes only uncommitted `.partial` data, and leaves committed segments/job metadata.
- Resume validates inputs and existing output segments, then starts at the first missing/invalid segment.
- If the project changed, the old snapshot may still resume because its referenced assets/settings were frozen. If required assets are missing, list them exactly.

## 12. Final validation

Minimum checks before success:

- container opens and all expected streams are present;
- codec, pixel dimensions, frame rate, sample rate, channels, and duration match the job;
- decoded first/middle/last video frames exist;
- decoded audio exists and non-silent expectation is met unless silent was selected;
- actual frame count is within the documented policy;
- video/audio end difference <= one video frame plus 10 ms;
- no negative/non-monotonic PTS/DTS;
- file size > minimum sanity threshold and checksum is recorded.

Export diagnostics store the command/settings and results, never media content.

