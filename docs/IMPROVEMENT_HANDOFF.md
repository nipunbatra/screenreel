# Screen Reel 0.2.0 verification — September 5, 2026

## Release state

The owner authorized UI access, tests, signing, installation, commits, pushes
and GitHub Pages publication after the lecture. The earlier foreground pause
is over. The signed final app is installed at `/Applications/Screen Reel.app`.
The final DMG has been accepted by Apple's notary service, stapled, and
assessed successfully by Gatekeeper, including the app inside the image.

Source changes are committed in `40875df`; the identity and website are in
`f9daeea`. Final verification passed. The release is
[Screen Reel 0.2.0](https://github.com/nipunbatra/screenreel/releases/tag/v0.2.0)
and the site is [Screen Reel](https://nipunbatra.github.io/screenreel/).
The release files are `dist/screenreel-0.2.0.dmg` and its SHA-256 checksum:
`00eb409ae7c909c8fc700d01b6dcec143f443e62289a9ce343d25bfba6d6b631`.
The installed executable matches the final signed build byte-for-byte.

## Changes

- Five ScreenCaptureKit surfaces, two pending screen frames, three pending
  camera frames; a bounded 4096-record input-event handoff. Loss is counted.
- Hardware HEVC/H.264 recording, encoder preparation before capture, and
  cancellation of thumbnail work when recording starts.
- Consumers are attached before asynchronous source startup. The shared
  screen/audio stream waits until every enabled track has a handler. This
  fixes initial frame loss while keeping the memory budget small.
- Playback retains actual surface pixels up to 1440p. Active scrubbing is
  lighter; recording and Studio export preserve native content pixels.
- Denoising uses reusable FFT buffers and real lookahead to compensate its
  512-sample delay, preserving narration onset and tail. The seeded benchmark
  median improved from 0.0614 to 0.0422 s per minute of audio (31%).
- Keystroke capture remains opt-in and now persists across JSON round trips.
- The product is **Screen Reel**, CLI `screenreel`. Bundle ID, project format,
  existing preferences and recordings stay compatible. Tests now actually
  read the checked-in legacy `.aks` fixture instead of skipping a renamed path.
- Simplified ribbon icon, regenerated native/website assets, responsive page
  with interactive framing controls, a direct download, privacy page and
  command-line examples. No new application or website dependency.
- Distribution supports the existing App Store Connect API key as well as
  keychain profiles. APFS DMGs are verified before/after signing. Fixed a
  pipefail/SIGPIPE signature-check bug and made downloaded checksums usable
  from the download directory. No credential was copied into this repository.

## Verification

- Final suite: **521 tests, zero failures**, with two intentional skips:
  the separately completed 30-minute export gate, and fixture regeneration
  (the released compatibility fixture must never be regenerated just to
  pass tests). All 520 executable checks ran across the normal/opt-in runs.
  Both legacy `.aks` compatibility tests now pass.
- After startup changes: 87 capture/real-recording golden tests passed,
  including a deterministic device that delivers screen, camera, microphone
  and system audio before its `start()` call returns.
- Thirty-minute styled export: 54,000/54,000 frames; A/V duration difference
  below 100 ms. Encoding 667.1 s (81 fps) at 180p, peak test RSS 515 MB.
- Final ten-minute 4K30 stress gate: **18,000/18,000 frames, zero dropped
  frames/buffers**, 28.8 million microphone samples and 150 independently
  decodable, checksum-verified segments. An earlier run lost one handoff
  buffer; that failed log is retained. The startup-fixed build passes the
  original zero-drop assertions. The synthetic generator paints BGRA frames
  at 2× real time; its CPU/RSS is not a live GUI recording measurement.
- Real 30-second 4096×2304/30 fps CLI capture with microphone: 901 frames,
  1,451,008 audio samples, zero dropped frames/buffers, about 69 MiB peak RSS,
  average process CPU 12.73%, peak 16.01%. Event capture was enabled but no
  clicks occurred; validation was healthy with an empty-click-track warning.
- App editor → play → restyle → export passed on copies of both a legacy
  recording and a new real recording. Metal drawables presented correctly.
  Raw-file hashes matched the originals. ffprobe verified HEVC dimensions,
  frame counts and AAC timing. Studio can enlarge the canvas to make room
  for padding while keeping the screen content at 1:1 source pixels.
- Native UX harness passed menus, hotkeys, countdown, area selection,
  recording-window hiding/restoration, and the template menu-bar icon.
- Website visually checked at 1440, 768 and 390 px with no horizontal
  overflow. Background, padding, focus/reset and clipboard UI worked;
  privacy page, local links/anchors, SVG/XML, JS/shell syntax and whitespace
  checks passed. Icons inspected at 16/32/128/1024 px and social-card size.

## Remaining local permission

The GUI app's Screen Recording access is off on this Mac. Enabling its
switch in System Settings requires the owner's account password. That prompt
was cancelled; no protection or TCC database was bypassed. CLI capture works
through the development environment's existing grant. Live GUI recording
and physical camera/microphone selection should be checked after the owner
unlocks that setting. The editor and control harnesses require no new grant.

The earlier reported system hang could not be attributed to Screen Reel:
no active recorder/build was present in that diagnostic sample; `suggestd`
was around 85% CPU, WindowServer around 45%, and swap was zero. An older
suspended export at 0% CPU was left alone. These are snapshots, not proof of
what caused a transient stall.

## Local evidence and repeat commands

Logs and test-only media are under `.build/improvement-checks/` (ignored):
`focused-tests.log`, `full-tests.log`, `schema-tests.log`, `long-tests.log`,
`startup-and-capture-tests.log`, `final-tests.log`, `live-startup-fixed.log`,
`final-release-build.log`, `final-notarization.log`, `editor-ux/`,
`final-editor-ux/`, `controls-ux/`, and `final-editor-export-probe.json`.
Only copies/test captures were edited. An interrupted empty harness package
was moved from the recordings browser into `interrupted-harness/` here.

```sh
# Fresh scratch paths avoid module caches from the old aks repository path.
swift test --scratch-path .build/background-20260905 --jobs 2
SCREENREEL_RUN_LONG_TESTS=1 swift test --scratch-path .build/background-20260905 --jobs 2 --filter TenMinuteGateTests
SCREENREEL_LONG_EXPORT_MINUTES=30 swift test --scratch-path .build/background-20260905 --jobs 2 --filter LongExportGateTests
Scripts/make-dmg.sh
Scripts/notarize.sh # set the existing NOTARY_* credentials in the environment
Scripts/release.sh --dry-run
```

See [benchmarks](BENCHMARKS.md), [distribution](DISTRIBUTION.md),
[brand sources](BRAND.md), and [ADR 0009](decisions/0009-bounded-capture-and-aligned-denoising.md).
