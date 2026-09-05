# Screen Reel 0.2.1 — gallery and editor performance

## Delivered

- Homepage gallery: two native editor screenshots with enlargement, three
  short production-rendered demos (zooms, cursor/clicks, framing), and real
  640×360 GIF plus 1280×720 H.264 MP4 downloads. No personal recording is used.
- Opt-in playback with one active decoder and automatic pause offscreen or
  in hidden tabs. No animation timers, autoplay or new website dependency.
- Waveform calculation uses Accelerate and exact bucket boundaries. Closing
  or switching projects cancels loading. A missing placeholder thumbnail no
  longer creates another composition/decoder alongside the real preview.
- Version 0.2.1 in the app, CLI and website; signed and notarized with the
  existing infrastructure. The installed app is `/Applications/Screen Reel.app`.

Website: [Screen Reel gallery](https://nipunbatra.github.io/screenreel/#gallery).
Installer and notes: [0.2.1](https://github.com/nipunbatra/screenreel/releases/tag/v0.2.1).
DMG SHA-256: `4076970040051cb87ecbd12c3d910e920aeb3ece7bdb9da2e97c612782a17911`.

## Verification

- Full Swift suite: 533 checks, zero failures, three intentional skips
  (the two long opt-in gates and fixture regeneration). The final 18-check
  focused run added two thumbnail tests and repeated waveform/preview checks;
  535 distinct Swift checks across these runs, with the same three skips.
  The capture/export long gates from 0.2.0 remain documented separately.
- Fourteen new Swift regressions: 12 waveform tests and two cache-miss tests.
  They cover exact short-timeline buckets, boundary transients, both stereo
  layouts, gaps/overlaps, committed/timeline ends, negative starts, 44.1 kHz,
  partial reads, invalid input, damaged PCM and task cancellation.
- Eighteen new website tests: ten playback lifecycle tests and eight
  offline asset/accessibility/budget checks. These now gate Pages deployment.
- Before/after optimized waveform benchmark: median 18.211 ms → 7.578 ms
  for two minutes of cached stereo 48 kHz audio, **58.4% less wall time**.
  This is waveform calculation, not whole-app CPU or a device capture test.
- Editor smoke: open 63 ms, first decoded frame 5 ms, 40 spread seeks
  14.6 ms/frame on the existing low-resolution synthetic fixture.
- Native editor harness: open generated project, play, click to re-aim a
  zoom, restyle, export. The generated capture has all 240 screen frames
  and zero handoff drops. Public MP4s/GIFs mechanically checked for exact
  dimensions, durations, frame counts, silence and fast-start structure.
- Browser checks at 1280, 768 and 390 px: no horizontal overflow; screenshots
  load, enlargement works, Escape restores link focus, each demo plays,
  another video pauses the first, and scrolling offscreen stops playback.
  Videos remain at readyState 0 before being requested. Viewport override reset.
- App and DMG accepted by Apple's notary service, tickets stapled, Gatekeeper
  and strict code-signature validation pass (including the mounted installer).

## Reproduce and evidence

[Gallery assets and provenance](FEATURE_GALLERY.md) documents the public-safe
source generator and encoding commands. [Benchmarks](BENCHMARKS.md) records
methodology and limits. Local logs and generated projects are retained under
`.build/gallery-checks/` and `.build/gallery-media-final/`; they are ignored.
The earlier installed bundle is copied under
`.build/gallery-checks/previous-installed.app` for local rollback.

No capture permission, login credential or device authorization was changed.
The separate GUI Screen Recording grant remains an owner-controlled macOS
setting as described in the 0.2.0 handoff.
