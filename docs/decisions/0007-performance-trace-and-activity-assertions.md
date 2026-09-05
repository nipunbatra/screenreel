# ADR 0007 — Per-recording performance trace and activity assertions

Date: 2026-09-05. Status: accepted.

## Context

The first real-world complaint about the app was "it is laggy and slows
everything down", and nothing in a recording could confirm or refute it:
the app's own CPU, the whole machine's load, encoder back-pressure, and the
cursor event tap's callback latency were all invisible after the fact.
Screen Recording permission is not available to test harnesses launched
from developer tooling, so the recording path cannot be profiled the way
the editor can; the recording has to explain itself.

Two mechanisms in the recording path can degrade the whole system rather
than just the app: a listen-only `CGEventTap` still gates WindowServer's
event delivery for every app until its callback returns (and macOS
silently disables a tap whose callback stalls), and a process whose only
window is hidden — the recorder hides it while recording — is eligible for
App Nap and lets idle sleep proceed.

## Decision

1. Every session writes `diagnostics/perf.jsonl`: one line per heartbeat
   (1 s) carrying the process's CPU over the interval (100 = one core),
   whole-machine CPU, resident size, thermal state, load average, the
   writer's frame and drop counters, handoff-buffer drops, and — through a
   probe the session owner installs — the event tap's event count,
   average/maximum callback latency, and re-enable count. At stop the
   session writes `diagnostics/perf-summary.json` (interval-weighted
   digest plus the final counters) and returns it in `StopSummary.perf`.
   `aks perf` reads both; the app keeps the digest and turns concerns
   (drops, tap stalls, thermal throttling, CPU saturation) into warnings.
2. Counters read by the trace are lock-free mirrors (`Atomic`) so the
   trace never queues behind an append on the writer actor.
3. The tap thread runs at user-interactive QoS, re-enables the tap on
   `tapDisabledByTimeout` / `tapDisabledByUserInput`, and caches per-event
   display geometry; the tap lifecycle is serialized under one lock.
4. The recording coordinator holds a `ProcessInfo` activity assertion
   (`userInitiated`, `idleSystemSleepDisabled`, `idleDisplaySleepDisabled`,
   `latencyCritical`) for the whole session; every exporter holds
   `userInitiated` + `idleSystemSleepDisabled` for the job.
5. A session-initiated stop (disk exhausted) notifies its owner
   (`Callbacks.onSelfStop`) before sealing the journal so externally owned
   producers (tap, pump, assertion) close first; event-chunk commits are
   refused once stopping.

## Consequences

- `diagnostics/` gains two files per recording; both are derived
  metadata, contain no pixels, audio, or key contents, and are ignored by
  validation and recovery. Old projects simply have none.
- The perf trace costs one `getrusage`/`host_statistics`/`task_info` call
  set and one small JSONL line per second — measured below 0.1% CPU.
- Activity assertions keep the display awake during a recording; that is
  the intended behavior for a screen recorder and is released at stop.
- `StopSummary` gained a `perf` field; its memberwise initializer changed
  (internal to CaptureCore).
