# 0010 — PNG screenshots and portable background music

Accepted 2026-09-05.

Screenshots use the same ScreenCaptureKit source filter and resolved pixel
geometry as recording. They are single native-resolution PNG files, saved
atomically after capture. They do not start audio, camera or event capture.

An optional `music` field in the edit document references an imported file
under `assets/music/`. Old documents default to no music. Import preserves
the original file and streams a 48 kHz stereo Float32 CAF working copy into
the package. Neither recording nor import rewrites raw capture media.

Music starts at output timeline zero, continues across cuts/speed changes,
and is trimmed with the video. It loops by default, with an editable gain
from zero to one and a loop toggle. Preview and both styled exporters use
the same track settings and timeline offset. Raw export remains raw.

Import and export use bounded PCM blocks. Import is cancellable, and a
failed import removes only its own temporary files. Removing music clears
the edit reference; assets remain available for undo. Missing or invalid
music produces an actionable error instead of a silently different export.

This is one background music track, not a multi-track audio workstation.
