# ADR 0006 — Offline license keys and GitHub Releases as the update channel

- Status: accepted
- Date: 2026-09-05

## Context

Screenreel is MIT-licensed and builds from source in two commands, but most
people will want a signed, notarized download, and the owner may sell
licenses to fund the project. Pricing, trials, and what a license unlocks
are not decided. The privacy stance (`docs/TECHNICAL_DESIGN.md` §11: local
operation, no account, no telemetry) must survive whatever is decided.

## Decision

1. **License keys are self-contained Ed25519 signatures** (`Licensing`
   target, Foundation + CryptoKit only). A key is
   `SR1-<base64url payload>-<base64url signature>`; the app verifies it
   against an embedded public key and never contacts a server. The payload
   carries `updatesUntil`, so the model is "perpetual license, one year of
   updates": the app compares its own build date to the window and reports
   it. Nothing is gated; `Entitlements.isLicensed` exists so a gate, if
   ever added, has one place to read from.
2. **GitHub Releases is the update channel.** The app's only network call is
   a GET to the "latest release" endpoint, manual or at most daily, and the
   user downloads the DMG in the browser. No self-updating framework, no
   third-party code, no appcast.
3. **The release pipeline is shell scripts in `Scripts/`** driven by a single
   `VERSION` file and `CHANGELOG.md`: `make-dmg.sh` → `notarize.sh` →
   `release.sh`. Each checks its preconditions and fails early instead of
   producing an unsigned or unnotarized artifact.

## Consequences

- A stolen private key would let someone issue keys; the private key lives
  outside the repository and rotation means adding a second public key to
  the verifier, not invalidating old keys.
- Key format changes require a new prefix (`SR2-…`), leaving `SR1` keys
  valid.
- The website and README describe the update check plainly; the privacy
  claim is now "one documented request to api.github.com", not "no network".
