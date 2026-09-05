# 0011 — Hold a static screen through Stop

Accepted 2026-09-05 after live silent-window captures ended before Stop.

ScreenCaptureKit delivers frames only when content changes. A silent recording
therefore cannot derive its end time solely from its last received frame.
Real-time screen sources opt into `holdsLastFrameUntilStopped`; offline and
synthetic sources retain their deterministic PTS-based duration.

At Stop, CaptureSession passes the stop timestamp (or pause start, when paused)
to VideoSegmentWriter. The final writer session ends at that timestamp, holding
the last image without adding encoded frames. Its committed descriptor records
the same extended end time. Container duration and preview seek behavior are
tested, including a ten-second video containing just one encoded frame.

No capture buffer is retained for the tail, and no timer encodes duplicate
frames while the screen is idle. Keeping a ScreenCaptureKit sample alive for
reuse was rejected after a live check showed it could stall compositor delivery.
The existing surface and handoff budgets stay unchanged.
