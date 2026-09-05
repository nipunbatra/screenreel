# Changelog

All notable changes to Screenreel. `Scripts/release.sh` publishes the section
matching `VERSION` as the GitHub release notes, so keep each section
self-contained and replace "Unreleased" with the date when cutting a release.

## 0.2.0 — Unreleased

Performance diagnosis and hardening, launch fix, and distribution plumbing.

- **Launch fix.** A signed build could launch as a bare Dock icon with no
  window: macOS restored the window state of a session that ended with the
  recorder window hidden (it is hidden while recording) or a killed
  process, and SwiftUI then never presented a window. The app now opts out
  of persistent UI state and always presents the recorder at launch.
- **Recording performance trace.** Every recording writes
  `diagnostics/perf.jsonl` (per second: the app's CPU next to the whole
  machine's, RSS, thermal state, load, frame/drop counters, cursor-tap
  latency) and `perf-summary.json`; `aks perf <project> --trace` prints
  it, the CLI prints the digest at stop, and the app records a one-line
  recording health string plus `[perf]` warnings for drops, tap stalls,
  thermal throttling, and CPU saturation.
- **Cursor event tap hardening.** The listen-only tap sits in
  WindowServer's delivery path for every app's input: its thread now runs
  at user-interactive priority, it re-enables itself when macOS disables
  it (a timed-out tap used to record nothing for the rest of the
  session), per-event display lookups are cached, and callback latency is
  measured. Cursor-shape polling no longer re-encodes an unchanged cursor
  ten times a second.
- **No App Nap or sleep during a recording or export.** The recorder
  holds a latency-critical activity assertion (no idle system or display
  sleep) for the whole session — the app hides its window while
  recording, which made it nap-eligible — and every exporter holds one
  for the job.
- **Stop robustness.** Two stops racing (pill + menu item, or an operator
  stop during the disk-full self-stop) share one result instead of
  failing with "stop() called twice"; the disk-full self-stop now closes
  the cursor tap and pump before sealing the journal; late event chunks
  are refused after finalization.
- **Start screen.** Activation no longer restarts live previews (which
  re-opened the camera preview session every time), screenshot refreshes
  are coalesced, and the camera preview session is reused for the same
  device. Thumbnails share one render context; failed renders are
  remembered so a damaged project is not re-parsed on every launch.
- **Project paths.** Packages created under `/private/tmp`-style paths
  no longer journal absolute segment paths (validation used to report
  `segment.openedNotCommitted` after a clean stop).
- **Harness.** `AKS_AUTOPILOT_DIR` runs operate on a copy of the project
  (they used to restyle the real recording), never trigger permission
  prompts, and accept `AKS_AUTOPILOT_PLAY_SECONDS`.

- **License keys.** New `Licensing` module: offline Ed25519-verified keys
  (`SR1-…`) carrying licensee, tier (personal/team), seats, and an
  `updatesUntil` window that the app compares to its own build date.
  *Enter License…* in the app menu pastes and validates a key and shows the
  status. Nothing is gated — every feature works without a key.
- **Update check.** *Check for Updates…* and an automatic daily check
  (*Check for Updates Automatically*, on by default) query GitHub Releases
  and offer Download / Later / Skip This Version. This is the app's only
  network request and sends no identifiers.
- **Release pipeline.** `VERSION` file stamped into the bundle
  (`CFBundleShortVersionString`, `CFBundleVersion`, `SRBuildDate`);
  `Scripts/make-dmg.sh`, `Scripts/notarize.sh`, `Scripts/release.sh` for a
  signed, notarized, stapled DMG published to GitHub Releases with a stable
  `Screenreel.dmg` download link. Documented in `docs/DISTRIBUTION.md`.
- **Website.** Download section with system requirements; a Pro-license
  block exists but stays hidden until pricing is decided.
- `Scripts/make-license.swift` generates the signing keypair and issues keys.

## 0.1.0 — 2026-08-30

Initial public release: segmented crash-safe recorder, editor with
click-driven zooms, captions, camera PiP, styled/raw/GIF export, and the
`aks` CLI.
