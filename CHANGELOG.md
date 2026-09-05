# Changelog

All notable changes to Screenreel. `Scripts/release.sh` publishes the section
matching `VERSION` as the GitHub release notes, so keep each section
self-contained and replace "Unreleased" with the date when cutting a release.

## 0.2.0 — Unreleased

Distribution plumbing. No recording, editing, or export behaviour changed.

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
