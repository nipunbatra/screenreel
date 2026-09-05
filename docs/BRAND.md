# Screenreel brand

The mark is a single strip of film folded into the initial **S**. The strip
carries the frames of a take; the newest frame, at the strip's tail, is coral:
the take being written right now. Screen + reel + "never loses a take" in one
object, drawn as a physical thing sitting on a light glass tile so it reads
next to Apple's own icons.

Everything below is generated from SVG sources in `Assets/` by
`Scripts/make-icons.sh`; nothing is hand-exported.

## The concepts that were considered

Three genuinely different directions were drawn, rendered at 512/128/32/16 px
with AppKit, and compared on a Dock-like strip beside Notes, QuickTime, Photos
and Keynote.

| | Concept | Verdict |
|---|---|---|
| A | **Frames** — a reel of screen frames fanning out behind a glass front screen (coral, mint) | Pretty and Sequoia-like, but reads as a generic stack of cards (Wallet, Photos) and says nothing specific about Screenreel. |
| B | **Lens** — a zoom lens resting on a screen, genuinely magnifying the coral region beneath it | Clear zoom story, but a loupe on a screen is the "search / inspect" glyph (Preview, Spotlight); weak at 16 px. |
| C | **Reel** (winner) — the folded strip S with a coral live frame | The only one that is ownable at every size: a crisp glyph in the menu bar, a confident tile in Finder, a small sculpture in the Dock. It doubles as the wordmark's initial and it is the name, not an illustration of the category. |

Rejected on the way: a red record dot on a screen (the category cliché), a
rectangular spiral strip (reads as a paperclip / "@" at small sizes) and a rim-lit
outline glyph (the flat-web-logo look).

## Palette

| Token | Hex | Use |
|---|---|---|
| Ink (highlight) | `#2B416A` | top of the strip gradient |
| Ink | `#1B2B4A` | the strip; wordmark text on light grounds |
| Ink (deep) | `#0E1830` | bottom of the strip; shadows; dark brand ground |
| Coral | `#FF6A4A` | the live frame, glow, the only warm colour |
| Coral (light) | `#FF9A7E` | top of the live-frame gradient |
| Coral (deep) | `#E8482F` | bottom of the live-frame gradient |
| Ground (light) | `#FFFFFF` → `#E1E7EF` | the icon tile, top to bottom |
| Ground (dark) | `#223760` → `#0E1830` | Open Graph card, dark site sections |
| Mint | `#5EE7BD` | optional secondary accent for the website/UI only; never on the mark |

Coral appears once per composition, always as the live frame at the strip's
tail. Everything else is ink on ground.

## Geometry (1024 canvas)

- **Stage**: Apple's macOS icon grid — an 824 × 824 rounded rect, corner
  radius 185, centred in a 1024 canvas (100 px transparent margin), with
  Apple's soft shadow (y +10, blur σ 11, 30 % black). This was measured from
  Apple's own `.icns` files, not guessed.
- **Strip**: one stroked path, width 118, round caps. Centreline rows at
  y = 300 / 512 / 724 (212 apart) joined by exact semicircles (r 106);
  x from 302 to 722. The stroked mark's bounding box is 538 × 542.
- **Frames**: pane windows 66 wide across the strip, 86 long, divided by
  14 px frame lines, white at 11 %. The pattern is phased so the last pane
  ends exactly one frame line before the live frame.
- **Live frame**: 88 long, 66 wide, round caps, at the tail (bottom-left), with
  a coral radial glow (r 170, 30 % → 0) beneath it.
- **Depth**: the strip's shadow is a blurred copy of itself (σ 9, y +14,
  26 % deep ink). No rims, no outlines, no glows other than the coral one.

### Sizes and variants

| Pixel size | Source | Notes |
|---|---|---|
| 64 – 1024 | `Assets/AppIcon.svg` | full art |
| 16, 32 | `Assets/AppIcon-small.svg` | no pane detail; the last 40 px of the tail plus its cap are coral so the live frame survives as a visible tip |

`Assets/AppIcon.icns` contains the ten standard representations (16, 32, 128,
256, 512 at 1× and 2×); 16, 16@2x and 32 use the small variant, 32@2x and up
the full art.

## Clear space and minimum sizes

- Around the **mark** (icon tile or flat S): at least half the mark's height
  on every side. Nothing else enters that space.
- Around the **wordmark**: half the mark's height on every side; the mark and
  the text are one object and are never separated, restacked or re-spaced.
- **Minimum**: mark 16 px; wordmark 24 px tall (the coral tail becomes a dot,
  which is intended); Open Graph card only at 1200 × 630.

## Wordmark

`Assets/brand/wordmark.svg` is the mark beside "Screenreel" set in
**Inter Display SemiBold** (SIL Open Font License), converted to outlines, so
nothing depends on a font at render time. The cap height is optically centred
on the mark; tracking −1.2 %. On dark grounds the text and strip are white
and the live frame stays coral (see the OG card). The name is always
"Screenreel": one word, capital S, never "ScreenReel" or "Screen Reel".

## Menu bar

`Assets/MenuBarIcon.svg` is the strip alone, black on transparent, on an
18 × 18 pt canvas with the S 14 pt tall (3 pt strokes, 2.5 pt counters). It is
rendered as `Assets/MenuBarIconTemplate.png` (18 px) and
`Assets/MenuBarIconTemplate@2x.png` (36 px). The `Template` suffix is what
makes AppKit treat an image loaded with `NSImage(named:)` as a template
(tinted to the menu bar's appearance, dimmed when disabled); an image loaded
with `NSImage(contentsOf:)` needs `isTemplate = true` set explicitly. The
status item currently uses SF Symbols (`record.circle`) and can switch to this
mark without changing its size.

## Do not

- Do not put a red/coral record dot anywhere; the live frame is the record cue.
- Do not recolour the strip, add a second accent, or move the coral off the tail.
- Do not outline, rim-light, emboss or add a glow to the S.
- Do not rotate, mirror, skew, stretch or set the S in a font.
- Do not draw the icon without its stage (the light tile) in Dock/Finder
  contexts; on the web use the full-bleed `website/assets/icon.png`.
- Do not put the light tile on a busy background without its clear space.
- Do not use mint on the mark or in the icon.
- Do not hand-export rasters; edit the SVG and run the pipeline.

## Files

| File | Size | Purpose |
|---|---|---|
| `Assets/AppIcon.svg` | 1024 × 1024 | icon source (full art) |
| `Assets/AppIcon-small.svg` | 1024 × 1024 | icon source for 16 / 32 px |
| `Assets/AppIcon.icns` | 16 – 1024, 1× and 2× | bundled by `Scripts/make-app.sh` |
| `Assets/AppIcon-1024.png` | 1024 × 1024 | Dock rendering with margin and shadow |
| `Assets/MenuBarIcon.svg` | 18 × 18 pt | menu-bar source |
| `Assets/MenuBarIconTemplate.png`, `@2x` | 18 / 36 px | template images for AppKit |
| `Assets/brand/wordmark.svg` | 1005 × 160 | horizontal lockup, ink on transparent |
| `Assets/brand/og-image.svg` | 1200 × 630 | Open Graph source |
| `Assets/brand/make-sources.py` | — | design-time generator for the SVGs above |
| `website/assets/icon.png` | 1024 × 1024 | full-bleed squircle, transparent corners, no shadow |
| `website/assets/favicon.png` | 64 × 64 | same crop |
| `website/assets/og-image.png` | 1200 × 630 | icon + wordmark + tagline on the dark ground |

## Pipeline

```sh
Scripts/make-icons.sh            # SVG sources -> every raster above (about 7 s)
Scripts/make-icons.sh out.icns   # only the .icns (used by make-app.sh as a fallback)
```

It needs nothing beyond macOS: `Scripts/render-svg.swift` rasterises with
AppKit (CoreSVG) and `iconutil` packs the iconset. The output is
byte-identical across runs on the same macOS version; commit the regenerated
files together with the SVG change. `Scripts/make-app.sh` copies
`Assets/AppIcon.icns` into the bundle and only rebuilds it when the file is
missing.

To re-set the wordmark or move geometry, edit and run the generator (needs
Inter Display in `~/Library/Fonts` or `SCREENREEL_FONT_DIR`):

```sh
uv run --with fonttools --with uharfbuzz Assets/brand/make-sources.py
Scripts/make-icons.sh
```

### Authoring rules for the SVG sources

CoreSVG (what AppKit uses) renders gradients, `clipPath`, `mask`, opacity and
plain `feGaussianBlur` identically to librsvg and browsers, but it silently
ignores `feOffset` / `feMerge` / `feColorMatrix` / `feDropShadow` /
`mix-blend-mode`, and it mis-blurs a filter applied directly to a stroked
path. So: shadows are blurred copies of the shape, filters go on a `<g>` or on
a filled shape, and no blend modes. Check any change with the four renders the
pipeline produces (1024, 128, 32, 16) before committing.
