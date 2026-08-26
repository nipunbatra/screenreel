# Manual tests

Automated coverage lives in `Tests/`; these procedures cover what automation
cannot: real ScreenCaptureKit capture, real permissions, and a human pulling
the plug. Record results (date, machine, macOS, outcome) in the PR or commit
that claims the milestone.

## M0-A. Real capture smoke

1. Build: `swift build -c release`.
2. `\.build/release/aks env` — confirm your display is listed. If not, grant
   Screen Recording permission to the terminal and retry.
3. `\.build/release/aks record --duration 60 --output ~/Movies/aks-manual.aks`
   while speaking into the microphone, moving the cursor, and clicking.
4. When it stops, confirm the summary reports validation healthy.
5. `\.build/release/aks validate ~/Movies/aks-manual.aks` — healthy.
6. Open `~/Movies/aks-manual.aks/raw/screen/display-*.mov` in QuickTime — it
   must play, with **no cursor baked in**.
7. Play a `raw/microphone/*.caf` in QuickTime — your voice.
8. `aks extract ~/Movies/aks-manual.aks /tmp/aks-extract` — inspect
   `events.csv`: cursor positions and your clicks with timestamps.

## M0-B. Forced-quit during real capture

1. Start a recording without `--duration` limit concerns:
   `\.build/release/aks record --duration 600 --output ~/Movies/aks-kill.aks`
2. After 30-60 seconds of real screen/mic activity, force-kill it:
   `kill -9 $(pgrep -f 'aks record')` — or close the terminal window.
3. `aks validate ~/Movies/aks-kill.aks` — must report the incomplete session
   and committed segments, with **zero** checksum/decode errors.
4. `aks recover ~/Movies/aks-kill.aks` — recovered copy reports healthy;
   original untouched (session.lock and `.partial` files still present).
5. Play the recovered copy's last committed screen segment in QuickTime; its
   content must be from within a few seconds of the kill.
6. Repeat once during the first 5 seconds of recording (open first segment)
   and once immediately after pressing Ctrl-C would have been natural (late
   pause), per the forced-termination matrix in ACCEPTANCE_TESTS §2.

## M0-C. Power loss (when practical, laptop on empty battery or a test Mac)

As M0-B but hold the power button instead of `kill -9`. After reboot, run
`aks validate` and `aks recover`. Expect the same guarantees; APFS + F_FULLFSYNC
writes are designed for exactly this.

## M0-D. Microphone withdrawal during real capture

1. Start a recording with an external USB/Bluetooth microphone selected as the
   system default input.
2. Unplug it mid-recording.
3. Within ~2 seconds the terminal must show `WARNING [audio.micSilent] ...`
   (or a `deviceChanged` fault), and recording must continue.
4. After stop, `aks inspect --journal` must show the fault record, and
   validation must not claim a fully healthy mic-enabled project if the mic
   track is empty.

## M0-E. Permission-denied flows

1. Remove Screen Recording permission for the terminal (System Settings →
   Privacy & Security), run `aks record` — expect an actionable error naming
   the permission, not a hang or crash.
2. Deny Input Monitoring; `aks record` must record screen/audio and print the
   events-disabled warning.
