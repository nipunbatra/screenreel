# Distribution: signing, notarization, releases, licenses, updates

This document is the runbook for shipping a Screen Reel build to people who
did not compile it themselves, and for the mechanisms that support selling
it later. Everything here is **plumbing**: pricing, trials, and what (if
anything) a license unlocks are undecided, and the app gates nothing today.

## What exists

| Piece | Where | State |
| --- | --- | --- |
| Version of record | `VERSION` (single line, `MAJOR.MINOR.PATCH`) | read by `make-app.sh`, `make-dmg.sh`, `notarize.sh`, `release.sh` |
| App bundle | `Scripts/make-app.sh` | stamps `CFBundleShortVersionString`, `CFBundleVersion`, `SRBuildDate` |
| Signed DMG | `Scripts/make-dmg.sh` | Developer ID + hardened runtime + timestamp; `ALLOW_ADHOC=1` for local tests |
| Notarization | `Scripts/notarize.sh` | `notarytool --wait`, staple, `spctl` assessment of DMG and app |
| GitHub release | `Scripts/release.sh` | tag `v$VERSION`, upload DMG (+ stable `screenreel.dmg` alias), notes from `CHANGELOG.md` |
| License keys | `Sources/Licensing`, `Scripts/make-license.swift` | offline Ed25519 verification; production public key is a placeholder |
| License UI | `Sources/ScreenreelApp/LicenseView.swift`, `Entitlements.swift` | app menu → Enter License…; nothing gated |
| Update check | `Sources/ScreenreelApp/UpdateCheck.swift` | manual + automatic (≤ 1/24 h); the app's only network call |
| Website | `website/index.html` | Build instructions, release listing, and open-format documentation; no purchase gating |

The human-facing bundle is `Screen Reel.app`. Release filenames use the
space-free `screenreel` prefix (`ARTIFACT_NAME`) independently of `APP_NAME`.
Bundle ID, signing identities, entitlements, notarization keychain profile,
and update endpoint are unchanged by the display-name change.

## Switches the owner must flip

1. **Production license public key** — `Sources/Licensing/LicenseVerifier.swift`,
   `LicensePublicKeys.productionBase64`. It currently holds the public half of
   a throwaway keypair whose private half was discarded, so **no key can
   activate** until it is replaced. The license window shows an orange
   developer note while the placeholder is in place, and
   `LicenseKeyTests.testPlaceholderProductionKeyAcceptsNothing` asserts it;
   flip that test's expectation when the real key is installed.
2. **Purchase link** — `Sources/ScreenreelApp/Branding.swift`, `Branding.purchaseURL`.
   `nil` hides every "Buy a License…" button. Set it to the checkout page.
3. **Website pricing** — the site currently offers the free MIT-licensed app.
   Add purchase UI only after pricing and a checkout destination are decided.
4. **Gating** — `Sources/ScreenreelApp/Entitlements.swift` exposes `isLicensed` and
   `updatesCovered`. Nothing reads them to restrict behaviour. When a gate is
   introduced, read it from `Entitlements` so the license window, tests, and
   the feature agree.

## One-time setup on the release Mac

Reuse working machine-wide credentials. These setup steps are only needed
when an identity or notarization credential is actually absent.

1. **Developer ID Application certificate**
   - Create at developer.apple.com → Certificates → *Developer ID Application*.
   - Install it in the **login** keychain. Confirm:
     `security find-identity -v -p codesigning` lists
     `"Developer ID Application: <Name> (<TEAMID>)"`.
2. **notarytool credentials** (stored in the keychain under a profile name):
   ```bash
   xcrun notarytool store-credentials screenreel-notary \
       --apple-id <apple-id-email> --team-id <TEAMID> --password <app-specific-password>
   ```
   The app-specific password comes from account.apple.com → Sign-In and
   Security → App-Specific Passwords. `Scripts/notarize.sh` uses the profile
   name `screenreel-notary` (override with `NOTARY_PROFILE=…`).
   An existing App Store Connect API key can be used instead, including on
   unattended release machines. Set `NOTARY_KEY_PATH` to the private `.p8`
   file, `NOTARY_KEY_ID` to its key ID and `NOTARY_ISSUER_ID` to its issuer ID
   when running `Scripts/notarize.sh`. The key is read in place and is never
   copied into the repository or release. Do not create another credential
   if the machine already has a working shared key.
3. **Unlocked keychain.** `codesign` fails with `errSecInternalComponent` when
   the login keychain is locked, which is the normal state over SSH and in
   agent sessions. Unlock it in the same shell before building:
   ```bash
   security unlock-keychain ~/Library/Keychains/login.keychain-db
   ```
   Every script checks for the identity and fails early with this hint rather
   than producing an unsigned artifact.
4. **`gh` CLI** authenticated for github.com (`gh auth status`). `release.sh`
   refuses to run otherwise.

## Cutting a release

App builds use `.build/distribution` to isolate release caches from test and
pre-rename caches. Override it with `BUILD_PATH`; `BUILD_JOBS` defaults to 2.

```bash
# 1. bump the version and write the changelog section
echo 0.2.0 > VERSION
$EDITOR CHANGELOG.md            # "## 0.2.0 — 2026-09-05" (no "Unreleased")
git commit -am "Release 0.2.0"

# 2. build + sign
security unlock-keychain ~/Library/Keychains/login.keychain-db
Scripts/make-dmg.sh             # → dist/screenreel-0.2.0.dmg (signed)

# 3. notarize + staple + Gatekeeper assessment
Scripts/notarize.sh             # → same file, stapled; fails loudly if Apple rejects

# 4. tag + publish (checks clean tree, main, stapled DMG, changelog section)
Scripts/release.sh --dry-run
Scripts/release.sh
```

`release.sh` uploads three assets: `screenreel-<version>.dmg`, an identical
`screenreel.dmg` (the permanent `releases/latest/download/screenreel.dmg`
asset path), and a SHA-256 file using the downloaded file’s basename. The
website links directly to the installer and to its release notes. Both the
DMG and the app inside it must pass Gatekeeper before publication.

Images use APFS in a compressed UDIF container and are verified before and
after signing. The HFS+ builder on the release host returned success while
producing invalid block offsets; signature verification alone missed it.

### Local test DMG without a certificate

`ALLOW_ADHOC=1 Scripts/make-dmg.sh` builds `dist/screenreel-<version>-unsigned.dmg`.
It opens on the building Mac only; `notarize.sh` and `release.sh` refuse it.
The same switch works for the bare bundle — `ALLOW_ADHOC=1 Scripts/make-app.sh`
skips identity lookup and signs ad-hoc, which is the way to build when a
Developer ID identity exists but the keychain is locked (otherwise the
default path tries it and stops at `errSecInternalComponent`).

### Architecture

`swift build` produces a binary for the host architecture; the published
0.2.0 DMG targets Apple silicon and macOS 15+. Intel users can build the
same sources on an Intel Mac with macOS 15 and Swift 6. Universal packaging
is not yet wired into `make-app.sh`.

## License keys

### Format

```
SR1-<base64url(payload)>-<base64url(signature)>
payload   = {"email":"…","id":"<uuid>","issuedAt":"2026-09-05T10:00:00Z","seats":1,"tier":"personal","updatesUntil":"2027-09-05T23:59:59Z"}
signature = Ed25519(payload bytes), 64 bytes
```

- Payload JSON is canonical: sorted keys, no whitespace, RFC 3339 UTC dates,
  `updatesUntil` omitted (not null) for perpetual updates.
- `-` is part of the base64url alphabet, so the parser takes the **last 86
  characters** as the signature (64 bytes is always 86 characters) and
  requires a `-` before them.
- Verification is offline: no clock, network, or account. The app compares
  its own build date (`SRBuildDate`) against `updatesUntil` to say whether
  the build is covered; it does **not** refuse to run either way.
- Tiers: `personal`, `team` (with `seats`). Unknown tiers are rejected.

### Issuing

```bash
# once: generate the production keypair OUTSIDE the repository
swift Scripts/make-license.swift --generate-keys ~/secure/screenreel-license
#   → ~/secure/screenreel-license/screenreel-license.private   (mode 0600; back it up; never commit)
#   → ~/secure/screenreel-license/screenreel-license.public
#   prints the base64 public key → paste into LicensePublicKeys.productionBase64

# per customer
swift Scripts/make-license.swift --issue \
    --key ~/secure/screenreel-license/screenreel-license.private \
    --email someone@example.org --tier personal --updates-until 2027-09-05
swift Scripts/make-license.swift --issue --key … --email lab@example.org --tier team --seats 10

# sanity checks
swift Scripts/make-license.swift --inspect SR1-…
swift Scripts/make-license.swift --verify --public ~/secure/screenreel-license/screenreel-license.public SR1-…
```

The script mirrors the wire format by hand (it cannot import the package);
`Tests/LicensingTests/ScriptCompatibilityTests.swift` pins a key issued by
the script against a fixture public key so the two cannot drift silently.

Losing the private key means every issued key still works (the public key
is in the app) but no new keys can be issued; rotate by adding the new public
key to `LicenseVerifier(publicKeys:)` alongside the old one.

## Update check

- Endpoint: `https://api.github.com/repos/nipunbatra/screenreel/releases/latest`,
  one GET, 10-second timeout, ephemeral session (no cookies, no cache).
- Sent: nothing beyond a `User-Agent` of `Screenreel/<version> (update check)`.
  GitHub sees the requester's IP address, as with any HTTPS request.
- Compares `tag_name` (with `v` stripped) to `CFBundleShortVersionString`
  using `SemanticVersion`. Prereleases sort before their release.
- Manual: app menu → *Check for Updates…* — always reports (up to date,
  update available, or the error).
- Automatic: *Check for Updates Automatically* (default on;
  `UserDefaults` key `updates.automatic`), runs 8 s after launch if the last
  successful check is older than 24 h (`updates.lastCheck`), stays silent
  unless an update exists, and defers while the recording HUD is visible.
- *Skip This Version* stores `updates.skippedVersion`; a manual check ignores
  it. *Download* opens the DMG asset's `browser_download_url`, or the release
  page when the release has no DMG. The app never replaces itself.
- Development builds (`swift run`, no Info.plist) report version `0.0.0-dev`.

## Verification status

- `swift build` and `swift test --filter LicensingTests` pass; tests use
  keypairs generated at test time plus one script-issued fixture key.
- September 5, 2026: Developer ID signing, App Store Connect key
  authentication, notarization, stapling and Gatekeeper checks were
  exercised successfully. The machine's shared credentials are usable.
  The older keychain/`gh` limitation no longer applies.
- See `docs/IMPROVEMENT_HANDOFF.md` for the release's capture, export, UI
  and website verification results.
