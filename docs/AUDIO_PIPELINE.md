# Audio pipeline

## 1. Design intent

Screenreel must make the common failure—“the lecture video exists but the lecture voice is gone”—both unlikely and recoverable. Raw microphone and system audio are independent, segmented, timestamped tracks. Enhancement is a replaceable derivative, never the recording.

## 2. Capture contract

- Target 48,000 Hz using the device's actual channel layout.
- Persist raw PCM in CAF segments for the safest v0.1 path; evaluate lossless ALAC after recovery tests.
- Record source device UID/name, nominal and actual format, channel layout, buffer duration, and every route/format change.
- Continuously track RMS and true/estimated peak for the preflight meter and diagnostics.
- Persist an audio heartbeat at least every segment boundary so absence is detectable during capture.
- If no mic samples arrive for two seconds while microphone capture is enabled, show a prominent warning and journal the fault; the screen capture continues.
- System audio is a separate source/track. Never mix it with the mic during raw capture.

## 3. Time alignment

Normalize audio buffer timestamps to the session monotonic origin while retaining source host/sample times. The timeline stores an explicit per-track offset; automatic sync establishes the initial offset, and the editor can adjust it in milliseconds.

Handle discontinuities as gaps, not by silently stretching timestamps. At export, a gap policy inserts silence and logs the range. End-to-end drift target: <20 ms/hour.

## 4. Enhancement graph

The default local speech preset is built from open components:

```text
raw mic
  → decode/convert to float PCM, 48 kHz, mono analysis stream
  → DeepFilterNet3 noise suppression
  → speech normalization
  → loudness/peak analysis
  → encoded enhanced derivative
```

Reference command-line behavior for a fixture implementation:

```bash
ffmpeg -i INPUT -f wav -ar 48000 -ac 1 prepared.wav
deep-filter prepared.wav --output-dir out
ffmpeg -i out/prepared.wav -af "speechnorm=e=12.5:r=0.001:l=1" enhanced.wav
```

This is a behavioral starting point. Package/build DeepFilterNet independently under its license, record the exact model checksum/version, and validate quality before making it the default.

## 5. Product presets

- **Raw:** no processing.
- **Lecture (default):** DeepFilterNet3 + conservative speech normalization; target integrated loudness approximately -16 LUFS for mono speech, true peak <= -1 dBTP.
- **Light:** lower suppression strength; normalization only where needed.
- **Strong noise:** more suppression with an explicit artifact warning and easy A/B.

The UI exposes one enhancement toggle and preset in v0.1; advanced numeric parameters may be hidden under diagnostics until tested.

## 6. Cache and job model

Enhancement key:

```text
SHA256(raw asset checksums + selected channels + source time mapping
       + algorithm version + model checksum + all settings)
```

Write to `derived/audio-enhanced/<key>.partial`, validate, then atomically rename. A job file stores input checksums, current stage, processed sample range, output path, tool versions, and error. Segment-level processing may resume; the final derivative exposes a continuous timeline mapping.

Changing trim or gain does not necessarily invalidate enhancement. Changing source channel, raw asset, denoiser/model, resampling, or denoiser settings does.

## 7. Preview

- Audio enhancement runs before or independently of video proxies.
- Play raw audio until the enhanced derivative covers the playhead; cross-switch only on a short boundary or after pause to avoid a pop.
- A/B is level-matched as closely as possible so louder is not mistaken for better.
- Waveforms are generated for raw mic, enhanced mic, and system audio separately.

## 8. Mix and export

1. Decode raw/enhanced mic and system audio using the frozen edit snapshot.
2. Apply clip/time mappings and explicit offsets.
3. Apply track gain/mute/fades.
4. Mix in float with sufficient headroom.
5. Apply final limiter only when needed to meet the peak ceiling; do not re-run denoise.
6. Encode AAC 48 kHz. Use mono when there is only a mono voice track; retain stereo when system audio/music spatial information matters.

The final MP4 must contain an audio stream unless the user explicitly selected silent export. A zero-duration or near-zero-energy output is an export failure, not success.

## 9. Objective validation

For every enhanced asset and final export, record:

- decodable duration and sample count;
- sample rate/channel count;
- start/end timestamps and gaps;
- integrated loudness, loudness range, sample peak/true peak;
- clipped sample count;
- non-silent duration ratio;
- source-to-output time drift.

Automated gates must detect missing mic, swapped/empty channels, grossly over-suppressed silence, clipping, and duration mismatch. Perceptual quality still needs a small human fixture set: quiet room, fan/AC, keyboard, distance mic, breath/noise, and mic route change.

## 10. Failure behavior

- Denoiser failure: keep raw playback/export available, show the failed job and retry button.
- Missing model: explain source, size, checksum, and license before download; raw mode remains functional.
- Disk full: stop derivative generation, delete only its `.partial` output, never raw audio.
- Device disappears during capture: journal the change, warn live, continue other tracks, and create a gap until recovery.
- Format change: start a new segment with the new descriptor and convert at mix time.

