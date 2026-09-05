# Screenreel project format

## 1. Goals

- Recover after power loss or forced termination.
- Let ordinary media tools open raw tracks.
- Keep source media immutable.
- Support schema migration without rewriting large assets.
- Make corruption local: one bad segment should not destroy an hour.
- Allow a validator/CLI to explain and repair indexes independently of the GUI.

## 2. Package layout

A project is a directory with the `.screenreel` suffix:

```text
Lecture 2026-08-24.screenreel/
  manifest.json
  journal.jsonl
  session.lock
  raw/
    screen/
      display-1-000001.mov
      display-1-000002.mov
    microphone/
      mic-000001.caf
      mic-000002.caf
    system-audio/
      system-000001.caf
    camera/
      camera-000001.mov
  events/
    cursor-000001.jsonl.zst
    clicks-000001.jsonl.zst
    keyboard-000001.jsonl.zst
    cursors/
      descriptor-0001.json
      descriptor-0001.png
  edits/
    timeline.json
    captions.json
  derived/
    proxies/
    waveforms/
    audio-enhanced/
    thumbnails/
  jobs/
    export-<uuid>/job.json
    export-<uuid>/segments/
    enhancement-<uuid>.json
  diagnostics/
    capture.jsonl
    perf.jsonl              # one perf sample per second (ADR 0007)
    perf-summary.json       # interval-weighted digest + final counters
    recovery-<timestamp>.json
```

`session.lock` is an incomplete-session marker, not an OS lock that becomes the sole recovery signal. Its contents include session ID, PID, process start marker, created time, last committed sequence, and heartbeat time.

## 3. Manifest shape

Illustrative fields (formal JSON Schema must be checked into `Schemas/` in Milestone 0):

```json
{
  "format": "com.nipunbatra.screenreel.project",
  "schemaVersion": 1,
  "projectID": "UUID",
  "createdAt": "2026-08-24T10:00:00Z",
  "modifiedAt": "2026-08-24T10:30:00Z",
  "state": "recording|recoverable|ready",
  "clock": {
    "originContinuousTicks": 123,
    "timebaseNumer": 1,
    "timebaseDenom": 1,
    "originWallTime": "2026-08-24T10:00:00Z"
  },
  "tracks": [],
  "timeline": "edits/timeline.json",
  "generation": 42
}
```

Every referenced asset descriptor contains:

- stable ID and track type;
- relative path only (no `..` or absolute path);
- container/codec/pixel/audio format;
- source and normalized start/end timestamps;
- byte size and SHA-256 after commit;
- discontinuity/dropped-sample flags;
- commit sequence and tool/app version.

## 4. Event record

Use newline-delimited JSON during v0.1 for inspectability; chunk and zstd-compress only committed ranges. Each line includes `schemaVersion`, `sequence`, `timeNs`, `type`, and a type-specific payload.

Cursor movement example:

```json
{"schemaVersion":1,"sequence":991,"timeNs":1200340000,"type":"cursorMove","displayID":1,"xPx":1820.5,"yPx":742.0,"cursorID":"arrow-3","buttons":0}
```

Click example:

```json
{"schemaVersion":1,"sequence":992,"timeNs":1200410000,"type":"mouseDown","button":"left","xPx":1820.5,"yPx":742.0,"cursorID":"arrow-3","modifiers":[]}
```

Cursor descriptors store pixel size, backing scale, hotspot in source pixels, semantic family, source type, and asset checksum. Event coordinates are display-local physical pixels — `(globalPoint − displayBounds.origin) × backingScale` — plus the display ID (see ADR 0004); conversion to captured source coordinates uses the saved display/capture geometry effective at that time.

## 5. Journal

Each journal record contains a monotonic sequence, type, payload, previous-record hash, and record checksum. Required types:

- `sessionCreated`
- `trackStarted`
- `segmentOpened`
- `segmentCommitted`
- `eventChunkCommitted`
- `deviceChanged`
- `discontinuity`
- `pause`
- `resume`
- `editSnapshotCommitted`
- `sessionStopped`
- `validationCompleted`
- `sessionFinalized`

Recovery trusts committed media and journal ordering, not the last manifest alone.

## 6. Atomicity rules

- Write JSON to a sibling `.tmp`, flush file, rename over destination, then flush containing directory.
- Media is written to `.partial`; rename to final name only after container finalization and basic decode inspection.
- A segment is discoverable only after a matching `segmentCommitted` record is durable.
- Derived assets may be deleted/rebuilt; raw assets and journal may not.
- The manifest `generation` increments on every atomic edit save. Keep the previous two manifests as `.history/manifest-<generation>.json` until a clean close.

## 7. Recovery algorithm

1. Copy or snapshot metadata before repair.
2. Parse journal until the first invalid checksum/torn line.
3. Enumerate committed descriptors and actual raw files.
4. Validate containers, duration, timestamps, and checksums.
5. Recognize valid unjournaled finalized tail segments as orphans and offer to attach them; never assume.
6. Quarantine unreadable `.partial` tails by renaming; do not delete.
7. Reconstruct track indexes and duration from valid segments.
8. Rebuild manifest with state `recoverable` and a detailed report.
9. Rebuild derived assets lazily.
10. Open a recovered copy by default.

## 8. Versioning and migrations

- `schemaVersion` is an integer with a registered migration chain.
- Readers reject newer major schemas with an actionable message and still expose raw paths.
- Migrations produce a new metadata generation; never rewrite raw media unless a user explicitly exports/converts it.
- Tests keep at least one fixture for every released schema version.

## 9. Raw extraction guarantee

The Finder package menu and CLI provide **Reveal raw files** and `screenreel extract PROJECT DESTINATION`. Extraction copies or hard-links committed screen, mic, system-audio, and camera assets plus a CSV/JSON event export. It works even when the editor cannot load the timeline.
