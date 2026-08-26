# Cursor and zoom motion engine

## 1. Coordinate model

Keep four named spaces and never pass bare points between them:

```text
GlobalDisplayPixels → CapturedSourcePixels → ScreenLocalNormalized → OutputCanvasPixels
```

Each conversion is derived from time-varying capture/display geometry. Cursor hotspot is subtracted in sprite/source pixels before the camera transform. The screen and screen-anchored cursor use the same crop/base/zoom matrices.

## 2. Event time

Events are recorded directly against Aks's monotonic session origin. Imported/legacy event sources must store their source origin explicitly and normalize once:

```text
eventTimeNs = sourceEventTimeNs - sourceOriginTimeNs + trackOffsetNs
```

Never infer the origin from the first cursor move; it may occur seconds after recording begins.

## 3. Cursor state evaluation

At output time `t`:

1. Find the last event at or before `t` and the next event after it.
2. Determine target position, descriptor, button state, visibility, and idle time.
3. Evaluate position spring from a deterministic checkpoint before `t`.
4. Evaluate click scale/ring and optional tilt.
5. Resolve original or replacement sprite and hotspot.
6. Transform the cursor anchor through the same screen camera.
7. Draw at output resolution after screen texture sampling to keep it sharp.

Checkpoints every 0.5–1 second make random access deterministic without integrating from time zero. A checkpoint is invalidated only by motion settings or event changes before it.

## 4. Spring integrator

Use semi-implicit Euler with fixed 1 ms substeps for reference behavior:

```text
springForce  = -(value - target) × stiffness
dampingForce = -velocity × damping
acceleration = (springForce + dampingForce) / mass
velocity     = velocity + acceleration × dt
value        = value + velocity × dt
```

The implementation may add a mathematically equivalent closed-form evaluator later, but it must match reference fixtures at frame times.

### Recommended defaults

These values are starting presets, tuned by eye against reference recordings:

```text
cursor normal     stiffness 470, damping 70, mass 3
cursor quick hop  stiffness 530, damping 40, mass 1
cursor held       stiffness 1000, damping 40, mass 1
click scale       stiffness 700, damping 30, mass 1
screen camera     stiffness 200, damping 40, mass 2.25
```

- Use quick-hop motion when the next movement target arrives within 175 ms.
- Use held motion while a mouse button is down.
- Click squash transitions over roughly 130 ms toward 0.8 scale, then returns.
- Optional tilt derives from horizontal displacement over the preceding 400 ms, scaled gently and clamped to ±20 degrees.

Expose presets (Raw, Slow, Smooth, Mellow, Fast) plus advanced stiffness/damping/mass. Store numeric values in the project so preset definitions can evolve without changing old videos.

## 5. Cursor descriptors

Required fields:

- ID, pixel dimensions, backing scale, hotspot `(x,y)` in sprite pixels;
- asset path/checksum and source (`systemSnapshot`, `aksVector`, `touch`, `custom`);
- semantic family (`arrow`, `ibeam`, `pointingHand`, `crosshair`, `resize…`, `unknown`);
- optional fallback ID.

If an exact sprite cannot be legally or technically captured, use an original Aks vector of the semantic family. Never guess hotspot from dimensions when a descriptor supplies it.

## 6. Automatic zoom generation

Input: click events, cursor positions, source bounds, clip boundaries, and policy. Default policy:

- candidate starts 300 ms before a click;
- candidate ends 2500 ms after it;
- mouse-down and mouse-up may contribute but a physical click is de-duplicated;
- merge candidates whose gaps are <=2500 ms;
- ignore new click candidates in the final 1000 ms of a clip;
- clamp range start to >=1 ms and end to <=clip duration−800 ms;
- never span a cut, pause discontinuity, display change, or incompatible crop scene.

Store generated zooms as ordinary editable segments with `origin=generated` and a generator version. Regeneration previews a diff and does not overwrite hand-edited/manual segments without confirmation.

## 7. Auto focal point

Within a zoom range:

1. Group spatially/temporally nearby click/cursor points.
2. Use each group's bounding-box center as the desired target.
3. Normalize to screen-local coordinates.
4. Clamp based on zoom scale and visible output aspect so the source never reveals empty space.
5. Apply edge snapping; a starting snap ratio around 0.25 is a tuning fixture.
6. Interpolate target changes and drive camera scale/pan through the screen spring.

Manual zoom stores its focal point directly in screen-local normalized coordinates. Zoom scale supports 1.0–4.5×. `instant=true` skips spring interpolation at the boundary.

## 8. Transform composition

Use explicit matrices in this order:

```text
source crop
→ base fit/placement within padded canvas
→ zoom about focal point with pan clamping
→ screen-local effect transform
```

Apply the resulting screen matrix to the raw screen texture and cursor anchor. Screen corners/shadow belong to the transformed screen rectangle; the background remains fixed to the canvas. Camera overlay behavior during a screen zoom is a scene setting: fixed to canvas or coupled to screen.

## 9. Motion blur

Motion blur is an optional temporal sampling effect in final render. It must not change the evaluated cursor/camera path. Responsive preview may disable it. Accurate preview and export use the same shutter interval/sample pattern.

## 10. Determinism and tests

- Given project snapshot, engine version, frame time, and output size, commands are bit-for-bit stable.
- Seeking to frame N yields the same cursor/camera state as playing from frame 0.
- Test stationary, sparse, rapid, held-drag, descriptor change, display edge, crop, zoom overlap, cut boundary, and inactive-hide cases.
- Pixel fixtures include arrow and I-beam hotspots at 1×/1.5×/2× and screen zooms at multiple output aspects.

