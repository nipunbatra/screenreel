# 0008 — Metal preview surface with zero CPU readback

Status: accepted (2026-09-05)

## Context

The editor preview rendered every frame by asking Core Image for a
`CGImage` (`CIContext.createCGImage`), then handing that bitmap to SwiftUI
as `Image(decorative:)` with `.resizable()`, `.clipShape`, a border and a
`.shadow(radius: 24)`. On a 4096×2304 recording that is a GPU→CPU readback
of a multi-megapixel BGRA frame ~30 times a second, followed by SwiftUI
re-uploading it as a layer texture and re-blurring a large shadow layer per
frame. Measured on the reference project (M2 Max, 5K panel): the app sat at
41–43 % CPU during playback, WindowServer at 4.5–5.8 %.

`docs/TECHNICAL_DESIGN.md` names PreviewEngine "Metal-backed interactive
evaluation"; this decision makes the app's preview surface actually Metal.

## Decision

1. **Frames stay on the GPU.** `CompositionBox` returns the composed
   `CIImage` recipe (`ComposedFrame`, `@unchecked Sendable` because
   `CIImage` is immutable) instead of a `CGImage`. A `CAMetalLayer`-backed
   `NSView` (`MetalPreviewNSView`) renders it straight into the drawable's
   texture with `CIContext(mtlDevice:)` +
   `render(_:to:commandBuffer:bounds:colorSpace:)` on a private serial
   queue: one render in flight, latest frame wins, drawables acquired and
   presented on that same queue. Nothing draws while idle — no display
   link; a frame is drawn only when the player pushes one.
2. **Same composition graph.** Frames still come from
   `ProjectComposition.frame(atOutput:)`; only the final blit changed. The
   canvas is aspect-fitted into the drawable by `PreviewFit` (pure math,
   unit-tested), and the surface reports its own point size and backing
   scale so the parked frame renders at exactly the drawable's pixel size.
   Half-resolution playback/scrub and the placeholder thumbnail are
   unchanged.
3. **Static chrome around a dynamic surface.** The drop shadow and border
   are SwiftUI shapes laid out to the same fitted rect; the compositor
   rasterizes them once. The rounded corners are painted *into* the
   drawable (the frame is alpha-masked over the backdrop colour in the
   same encode), and the layer itself stays opaque and unmasked: a
   `CAMetalLayer` with `cornerRadius` + `masksToBounds` is composited
   through an offscreen copy that the compositor refreshes only when a
   transaction dirties the layer — presenting a drawable does not — so the
   masked version froze on its first frame while the render queue kept
   presenting (verified with WindowServer captures of the live window).
4. **The view hosts its layer.** `layer = metalLayer` before
   `wantsLayer = true` (layer-hosting): AppKit keeps the layer's geometry
   in step with the view and never manages its contents.
5. **Direct manipulation moves to AppKit.** SwiftUI gestures on an
   ancestor do not fire over a platform view, so the surface recognizes
   tap (≤ 4 pt travel) and drag-release (≥ 24 pt) itself with the same
   thresholds the `SpatialTapGesture`/`DragGesture(minimumDistance: 24)`
   pair used, and reports top-left-origin points. Pointer → canvas fraction
   is computed from the rendered canvas size and the surface bounds, not
   from a bitmap's dimensions. The surface accepts first mouse.
6. **Per-tick SwiftUI work is fenced off.** The transport bar and the
   preview canvas are their own `View`s, so the 30 Hz `timeNs` updates no
   longer re-evaluate `EditorView.body`. With a platform view in the tree,
   each such re-evaluation re-pushed the window-toolbar preference through
   `ToolbarBridge` and re-solved the toolbar's AppKit constraints — a fifth
   of the main thread during playback.
7. **Orientation is explicit.** The render destination is marked flipped:
   Core Image's origin is bottom-left, a Metal texture's first row is what
   the layer shows at the top, and the unflipped default put the bottom of
   the frame in that row (upside-down preview; `CIRenderDestination.h`).
8. **Harness snapshots read back deliberately.** `cacheDisplay` cannot see
   `CAMetalLayer` contents, so the autopilot renders the last frame through
   the surface's own encode path into an offscreen texture and composites
   it at the surface's rect, and beside it saves WindowServer's capture of
   the live window (`*-window.png`, via `CGWindowListCreateImage` looked up
   at runtime — capturing one's own window needs no Screen Recording
   grant; blank when the display is asleep). That readback exists only on
   the harness path. The harness also delivers a synthesized click through
   `NSWindow.sendEvent` and checks the selected zoom's focal moved
   (`tapAim=` in `report.txt`), records surface/sink diagnostics, and
   appends stage markers to `progress.txt`.

## Consequences

- Playback on the reference project (4096×2304, M2 Max, 5K panel, 20 s
  autopilot playback, `top` every ~3 s): app CPU 40.6–43.3 % → 12.7–14.1 %
  with the display asleep, and 39.9–47.1 % → 14.5–19.6 % with the display
  awake; effective preview rate unchanged (~28 fps, 461–465 frames over the
  16.4 s recording). WindowServer 4.5–5.8 % → 2.8–3.0 % and GPU 8–9 % → 8–9 %
  with the display asleep; the display-awake runs coincided with another
  session's test/harness load (WindowServer 24–44 %, GPU 12–30 % with no
  Screenreel running), so their WindowServer/GPU figures are not
  attributable. Remaining app CPU is decode + composition, not display.
- `PreviewPlayer.currentFrame` is gone; views use `hasRenderedFrame` for
  spinner/placeholder logic and never touch pixels.
- The preview surface requires a Metal device; `MTLCreateSystemDefaultDevice`
  returning nil leaves the surface blank (placeholder + spinner) rather
  than falling back to the CPU path. Every supported Mac (macOS 15+) has
  one.
- `framebufferOnly` is false on the layer because Core Image writes the
  drawable texture directly; the harness readback never touches drawables.
