# Changelog

All notable changes to Screen Reel. `Scripts/release.sh` publishes the section
matching `VERSION` as the GitHub release notes, so keep each section
self-contained and replace "Unreleased" with the date when cutting a release.

## 0.2.0 — 2026-09-05

Performance diagnosis and hardening, launch fix, the rename, and
distribution plumbing.

- **Screen Reel identity.** A simpler ribbon mark, matching app and menu-bar
  icons, and a responsive website with an interactive framing illustration.
  The app is `Screen Reel.app`; the CLI remains `screenreel` and the project
  format stays open and compatible with existing recordings.
- **Bounded capture memory.** A five-surface capture pool, two pending screen
  frames, three pending camera frames and a bounded event handoff prevent
  large backlogs. Thumbnail work stops when recording begins. The hardware
  encoder warms before capture and reports an actionable error if unavailable.
- **Clean capture startup.** Consumers are ready before devices emit, and
  the shared capture stream waits for every enabled track's handler. This
  avoids losing initial frames or audio while device startup completes.
- **Sharper playback.** Editor playback keeps actual display-surface pixels
  up to 1440p instead of always halving resolution. Active scrubbing still
  uses a lighter preview. Native-resolution recording and export stay intact.
- **Faster, aligned voice cleanup.** Reusable FFT buffers reduce the measured
  denoiser microbenchmark wall time by 31%. Real lookahead compensates its
  512-sample delay, preserving the start and tail of narration during export.
- **Keyboard opt-in persists.** Explicit keystroke capture survives a settings
  round trip; older projects continue to default to keyboard capture off.

- **Renamed from aks to Screenreel everywhere.** CLI binary `screenreel`
  (was `aks`), bundle identifier `com.nipunbatra.screenreel` (was
  `in.aks.app` — macOS treats this as a new app, so Screen Recording,
  Microphone and Input Monitoring must be granted once more), project
  packages `.screenreel` with format id `com.nipunbatra.screenreel.project`.
  Existing `.aks` packages and the `in.aks.project` id are read forever;
  `~/Movies/Aks` is renamed to `~/Movies/Screenreel` on first launch.
  Harness/test environment variables are now `SCREENREEL_*`.
- **Metal preview.** The editor renders straight into a Metal layer (no CPU
  readback); playback CPU on a 4K recording fell from ~41% to ~13–24%.

- **Launch fix.** A signed build could launch as a bare Dock icon with no
  window: macOS restored the window state of a session that ended with the
  recorder window hidden (it is hidden while recording) or a killed
  process, and SwiftUI then never presented a window. The app now opts out
  of persistent UI state and always presents the recorder at launch.
- **Recording performance trace.** Every recording writes
  `diagnostics/perf.jsonl` (per second: the app's CPU next to the whole
  machine's, RSS, thermal state, load, frame/drop counters, cursor-tap
  latency) and `perf-summary.json`; `screenreel perf <project> --trace` prints
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
- **Harness.** `SCREENREEL_AUTOPILOT_DIR` runs operate on a copy of the project
  (they used to restyle the real recording), never trigger permission
  prompts, and accept `SCREENREEL_AUTOPILOT_PLAY_SECONDS`.

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
  `screenreel.dmg` download link. Documented in `docs/DISTRIBUTION.md`.
- **Website.** Responsive layout, an interactive framing illustration,
  signed installer download, clear system requirements and a privacy page.
  No analytics, remote fonts, purchase gating or frontend dependencies.
- `Scripts/make-license.swift` generates the signing keypair and issues keys.

## 0.1.0 — 2026-08-30

Initial public release: segmented crash-safe recorder, editor with
click-driven zooms, captions, camera PiP, styled/raw/GIF export, and the
`screenreel` CLI.
