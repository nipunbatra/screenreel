# Manual tests

Automated coverage lives in `Tests/`; these procedures cover what automation
cannot: real ScreenCaptureKit capture, real permissions, and a human pulling
the plug. Record results (date, machine, macOS, outcome) in the PR or commit
that claims the milestone.

## M0-A. Real capture smoke

1. Build: `swift build -c release`.
2. `\.build/release/screenreel env` — confirm your display is listed. If not, grant
   Screen Recording permission to the terminal and retry.
3. `\.build/release/screenreel record --duration 60 --output ~/Movies/screenreel-manual.screenreel`
   while speaking into the microphone, moving the cursor, and clicking.
4. When it stops, confirm the summary reports validation healthy.
5. `\.build/release/screenreel validate ~/Movies/screenreel-manual.screenreel` — healthy.
6. Open `~/Movies/screenreel-manual.screenreel/raw/screen/display-*.mov` in QuickTime — it
   must play, with **no cursor baked in**.
7. Play a `raw/microphone/*.caf` in QuickTime — your voice.
8. `screenreel extract ~/Movies/screenreel-manual.screenreel /tmp/screenreel-extract` — inspect
   `events.csv`: cursor positions and your clicks with timestamps.

## M0-B. Forced-quit during real capture

1. Start a recording without `--duration` limit concerns:
   `\.build/release/screenreel record --duration 600 --output ~/Movies/screenreel-kill.screenreel`
2. After 30-60 seconds of real screen/mic activity, force-kill it:
   `kill -9 $(pgrep -f 'screenreel record')` — or close the terminal window.
3. `screenreel validate ~/Movies/screenreel-kill.screenreel` — must report the incomplete session
   and committed segments, with **zero** checksum/decode errors.
4. `screenreel recover ~/Movies/screenreel-kill.screenreel` — recovered copy reports healthy;
   original untouched (session.lock and `.partial` files still present).
5. Play the recovered copy's last committed screen segment in QuickTime; its
   content must be from within a few seconds of the kill.
6. Repeat once during the first 5 seconds of recording (open first segment)
   and once immediately after pressing Ctrl-C would have been natural (late
   pause), per the forced-termination matrix in ACCEPTANCE_TESTS §2.

## M0-C. Power loss (when practical, laptop on empty battery or a test Mac)

As M0-B but hold the power button instead of `kill -9`. After reboot, run
`screenreel validate` and `screenreel recover`. Expect the same guarantees; APFS + F_FULLFSYNC
writes are designed for exactly this.

## M0-D. Microphone withdrawal during real capture

1. Start a recording with an external USB/Bluetooth microphone selected as the
   system default input.
2. Unplug it mid-recording.
3. Within ~2 seconds the terminal must show `WARNING [audio.micSilent] ...`
   (or a `deviceChanged` fault), and recording must continue.
4. After stop, `screenreel inspect --journal` must show the fault record, and
   validation must not claim a fully healthy mic-enabled project if the mic
   track is empty.

## M0-E. Permission-denied flows

1. Remove Screen Recording permission for the terminal (System Settings →
   Privacy & Security), run `screenreel record` — expect an actionable error naming
   the permission, not a hang or crash.
2. Deny Input Monitoring; `screenreel record` must record screen/audio and print the
   events-disabled warning.

## Lag triage (any recording that "felt slow")

1. Record 60 s of normal work (typing, window switching, scrolling) with the
   usual settings.
2. Stop, then run `screenreel perf <project.screenreel> --trace`.
3. Read the digest line first: `avg CPU` is the app alone (100 = one core);
   `system` is the whole machine. A high `system` with a low app number means
   something else was loading the Mac. `tap max` above ~20 ms, or any
   `tap re-enabled`, means the cursor event tap stalled — that is felt as
   system-wide pointer lag. `dropped` above 0 means encoder back-pressure.
4. In the per-second table, find the seconds where `proc%`, `sys%`, or
   `tapMax` spike and correlate with what was happening on screen.
5. Attach `diagnostics/perf.jsonl` and `perf-summary.json` to the bug report;
   neither contains pixels, audio, or key contents.
