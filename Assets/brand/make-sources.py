#!/usr/bin/env python3
"""Design-time generator for the Screenreel brand SVG sources.

The committed SVGs in Assets/ are the sources of truth for the raster
pipeline (Scripts/make-icons.sh); this script is how those SVGs were built,
kept so the geometry stays in one place and the wordmark can be re-set.

    uv run --with fonttools --with uharfbuzz Assets/brand/make-sources.py

Writes Assets/AppIcon.svg, Assets/AppIcon-small.svg, Assets/MenuBarIcon.svg,
Assets/brand/wordmark.svg and Assets/brand/og-image.svg.

The wordmark is set in Inter Display (SIL Open Font License) and converted to
outlines here, so no rendering step depends on a font. Point
SCREENREEL_FONT_DIR at a directory containing InterDisplay-SemiBold.otf and
InterDisplay-Medium.otf (default: ~/Library/Fonts).
"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.dirname(HERE)
FONT_DIR = os.environ.get("SCREENREEL_FONT_DIR", os.path.expanduser("~/Library/Fonts"))

# ------------------------------------------------------------- palette ----
INK_HI, INK, INK_LO = "#2B416A", "#1B2B4A", "#0E1830"
CORAL, CORAL_HI, CORAL_LO = "#FF6A4A", "#FF9A7E", "#E8482F"
GROUND_HI, GROUND_LO = "#FFFFFF", "#E1E7EF"

# ---------------------------------------------------- strip geometry ------
# The strip is one stroked path: three rows joined by exact semicircles.
W = 118                  # strip width
L, R = 302, 722          # centreline x extents
T, M, B = 300, 512, 724  # centreline rows
RAD = (M - T) // 2       # 106
PANE_W = 66              # pane (frame window) height across the strip
PANE, GAP = 86, 14       # pane length and frame line along the strip
LIVE = 88                # live (coral) pane length at the tail
BBOX = (L - W / 2, T - W / 2, R + W / 2, B + W / 2)   # stroked strip bounds
MARK_W = BBOX[2] - BBOX[0]   # 538
MARK_H = BBOX[3] - BBOX[1]   # 542

STROKE = f'fill="none" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"'


def strip_path(tail_x=L):
    return (f"M{R} {T}H{L + RAD}A{RAD} {RAD} 0 0 0 {L} {T + RAD}"
            f"A{RAD} {RAD} 0 0 0 {L + RAD} {M}"
            f"H{R - RAD}A{RAD} {RAD} 0 0 1 {R} {M + RAD}"
            f"A{RAD} {RAD} 0 0 1 {R - RAD} {B}"
            f"H{tail_x}")


def strip_length(tail_x=L):
    return ((R - (L + RAD)) + math.pi * RAD + ((R - RAD) - (L + RAD))
            + math.pi * RAD + ((R - RAD) - tail_x))


# Pane pattern phase: the dashed pane path stops one frame line before the
# live pane; its last pane must end flush with the path end.
PANES_END_X = L + LIVE + GAP
PANES_LEN = strip_length(PANES_END_X)
PERIOD = PANE + GAP
DASH_OFFSET = (PANE - PANES_LEN) % PERIOD


# ------------------------------------------------------------- app icon ---
def icon_defs():
    return f"""<defs>
    <clipPath id="stage"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
    <linearGradient id="ground" x1="512" y1="100" x2="512" y2="924" gradientUnits="userSpaceOnUse">
      <stop stop-color="{GROUND_HI}"/><stop offset="1" stop-color="{GROUND_LO}"/>
    </linearGradient>
    <linearGradient id="ink" x1="512" y1="{T - W // 2}" x2="512" y2="{B + W // 2}" gradientUnits="userSpaceOnUse">
      <stop stop-color="{INK_HI}"/><stop offset="0.55" stop-color="{INK}"/><stop offset="1" stop-color="{INK_LO}"/>
    </linearGradient>
    <linearGradient id="coral" x1="512" y1="{B - W // 2}" x2="512" y2="{B + W // 2}" gradientUnits="userSpaceOnUse">
      <stop stop-color="{CORAL_HI}"/><stop offset="1" stop-color="{CORAL_LO}"/>
    </linearGradient>
    <radialGradient id="coralGlow" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate({L + LIVE // 2} {B}) scale(170)">
      <stop stop-color="{CORAL}" stop-opacity="0.30"/><stop offset="1" stop-color="{CORAL}" stop-opacity="0"/>
    </radialGradient>
    <filter id="stageShadow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="11"/></filter>
    <filter id="stripShadow" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="9"/></filter>
  </defs>"""


def icon_body(detail=True):
    d = strip_path()
    if detail:
        accent = f"""
    <!-- frames: pane windows divided by frame lines, along the whole strip -->
    <path d="{strip_path(PANES_END_X)}" fill="none" stroke="#FFFFFF" stroke-opacity="0.11" stroke-width="{PANE_W}"
          stroke-dasharray="{PANE} {GAP}" stroke-dashoffset="{DASH_OFFSET:.0f}"/>
    <!-- live frame: the take being written -->
    <circle cx="{L + LIVE // 2}" cy="{B}" r="170" fill="url(#coralGlow)"/>
    <path d="M{L + LIVE} {B}H{L}" fill="none" stroke="url(#coral)" stroke-width="{PANE_W}" stroke-linecap="round"/>"""
    else:
        accent = f"""
    <!-- small-size variant: the tail itself carries the live colour -->
    <path d="M{L + 40} {B}H{L}" {STROKE} stroke="url(#coral)"/>"""
    return f"""<!-- stage shadow (Apple's: y+10, ~30 %) and the light glass stage -->
  <rect x="100" y="110" width="824" height="824" rx="185" fill="#000000" fill-opacity="0.30" filter="url(#stageShadow)"/>
  <g clip-path="url(#stage)">
    <rect x="100" y="100" width="824" height="824" fill="url(#ground)"/>

    <!-- strip shadow (filter on the group: CoreSVG mis-blurs bare strokes) -->
    <g filter="url(#stripShadow)" transform="translate(0 14)">
      <path d="{d}" {STROKE} stroke="{INK_LO}" stroke-opacity="0.26"/>
    </g>
    <!-- the strip -->
    <path d="{d}" {STROKE} stroke="url(#ink)"/>
    <!-- top-edge light -->
    <path d="{d}" fill="none" stroke="#FFFFFF" stroke-opacity="0.07" stroke-width="{W - 8}" stroke-linecap="round" stroke-linejoin="round" transform="translate(0 -3)"/>{accent}
  </g>"""


def icon_svg(detail=True):
    note = "" if detail else "\n       Small-size variant (16/32 px): no pane detail, coral tail."
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <!-- Screenreel app icon. A single strip of film folded into the initial S;
       the newest frame at the strip's tail is coral: the take being written.
       Geometry: Apple's macOS icon grid (824 px stage, r=185, in a 1024 canvas).
       Only gradients, clip and plain feGaussianBlur (on groups/fills) are
       used so that CoreSVG (AppKit), librsvg and browsers render it alike.
       Generated by Assets/brand/make-sources.py.{note} -->
  {icon_defs()}

  {icon_body(detail)}
</svg>
"""


# ----------------------------------------------------------- flat mark -----
def mark_group(scale, tx, ty, ink, coral, live=True):
    """The strip as a flat mark (no stage, no shadow), scaled and placed so
    that its bounding box's top-left corner lands at (tx, ty)."""
    x0, y0 = BBOX[0], BBOX[1]
    g = (f'<g transform="translate({tx:.2f} {ty:.2f}) scale({scale:.5f}) translate({-x0:.0f} {-y0:.0f})">'
         f'<path d="{strip_path()}" {STROKE} stroke="{ink}"/>')
    if live:
        g += f'<path d="M{L + LIVE} {B}H{L}" fill="none" stroke="{coral}" stroke-width="{PANE_W}" stroke-linecap="round"/>'
    return g + "</g>"


def menubar_svg():
    """18x18 pt canvas; the S fills 14 pt; black on transparent."""
    size = 18
    s = 14 / MARK_H
    tx = (size - MARK_W * s) / 2
    ty = (size - 14) / 2
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 {size} {size}">
  <!-- Screenreel menu-bar mark: the strip alone, black on transparent.
       Rendered as MenuBarIconTemplate.png / @2x so AppKit tints it. -->
  {mark_group(s, tx, ty, "#000000", "#000000", live=False)}
</svg>
"""


# ------------------------------------------------------------ wordmark -----
def text_path(font_file, text, size, tracking=0.0):
    """Shape `text` with HarfBuzz (kerning on) and return (advance, path d)."""
    import uharfbuzz as hb
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    from fontTools.ttLib import TTFont

    font_path = os.path.join(FONT_DIR, font_file)
    if not os.path.exists(font_path):
        sys.exit(f"font not found: {font_path} (set SCREENREEL_FONT_DIR)")
    face = hb.Face(hb.Blob.from_file_path(font_path))
    hbfont = hb.Font(face)
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(hbfont, buf, {"kern": True, "liga": True})
    tt = TTFont(font_path)
    glyph_set = tt.getGlyphSet()
    order = tt.getGlyphOrder()
    scale = size / face.upem
    pen = SVGPathPen(glyph_set, ntos=lambda v: f"{v:.2f}")
    x = 0.0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        tpen = TransformPen(pen, (scale, 0, 0, -scale, (x + pos.x_offset) * scale, -pos.y_offset * scale))
        glyph_set[order[info.codepoint]].draw(tpen)
        x += pos.x_advance + tracking * face.upem
    return x * scale, pen.getCommands()


CAP_HEIGHT = 0.727   # Inter cap height in em


def lockup(ink, coral, text_fill, mark_h=160.0, font_size=150.0, gap=46.0):
    """Mark + 'Screenreel'; returns (svg fragment, width, height)."""
    s = mark_h / MARK_H
    mark_w = MARK_W * s
    adv, d = text_path("InterDisplay-SemiBold.otf", "Screenreel", font_size, tracking=-0.012)
    baseline = (mark_h + CAP_HEIGHT * font_size) / 2   # cap height centred on the mark
    frag = (mark_group(s, 0, 0, ink, coral)
            + f'\n  <path transform="translate({mark_w + gap:.2f} {baseline:.2f})" fill="{text_fill}" d="{d}"/>')
    return frag, mark_w + gap + adv, mark_h


def wordmark_svg():
    frag, w, h = lockup(INK, CORAL, INK)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{w:.0f}" height="{h:.0f}" viewBox="0 0 {w:.0f} {h:.0f}">
  <!-- Screenreel wordmark: the mark + "Screenreel" in Inter Display SemiBold
       (SIL Open Font License), converted to outlines. Keep clear space of at
       least half the mark's height on every side. -->
  {frag}
</svg>
"""


def og_svg():
    """1200x630 Open Graph card: the app icon tile + wordmark + tagline."""
    W_, H_ = 1200, 630
    icon_scale = 0.32                       # stage = 824 * 0.32 = 264 px
    stage = 824 * icon_scale
    font_size = 152.0
    adv, d_name = text_path("InterDisplay-SemiBold.otf", "Screenreel", font_size, tracking=-0.012)
    tag_size = 34.0
    tag_adv, d_tag = text_path("InterDisplay-Medium.otf", "The Mac recorder that never loses a take", tag_size)
    gap = 64
    total_w = stage + gap + adv
    x0 = (W_ - total_w) / 2
    cy = H_ / 2 - 6
    icon_tx = x0 - 100 * icon_scale         # place the stage, not the canvas
    icon_ty = cy - stage / 2 - 100 * icon_scale
    text_x = x0 + stage + gap
    name_baseline = cy + CAP_HEIGHT * font_size / 2 - 22
    tag_baseline = name_baseline + 74
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W_}" height="{H_}" viewBox="0 0 {W_} {H_}">
  <!-- Screenreel Open Graph card: the icon and wordmark on the ink ground.
       Text is outlined Inter Display (SIL OFL). Generated by make-sources.py. -->
  <defs>
    <linearGradient id="ogGround" x1="600" y1="0" x2="600" y2="630" gradientUnits="userSpaceOnUse">
      <stop stop-color="#223760"/><stop offset="1" stop-color="{INK_LO}"/>
    </linearGradient>
    <radialGradient id="ogLight" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(600 -60) scale(780 420)">
      <stop stop-color="#5F7BAA" stop-opacity="0.35"/><stop offset="1" stop-color="#5F7BAA" stop-opacity="0"/>
    </radialGradient>
    <radialGradient id="ogCoral" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate({x0 + 40:.0f} {cy + 120:.0f}) scale(300)">
      <stop stop-color="{CORAL}" stop-opacity="0.20"/><stop offset="1" stop-color="{CORAL}" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="{W_}" height="{H_}" fill="url(#ogGround)"/>
  <rect width="{W_}" height="{H_}" fill="url(#ogLight)"/>
  <rect width="{W_}" height="{H_}" fill="url(#ogCoral)"/>
  <g transform="translate({icon_tx:.2f} {icon_ty:.2f}) scale({icon_scale})">
    {icon_defs()}
    {icon_body(True)}
  </g>
  <path transform="translate({text_x:.2f} {name_baseline:.2f})" fill="#FFFFFF" d="{d_name}"/>
  <path transform="translate({text_x + 6:.2f} {tag_baseline:.2f})" fill="#FFFFFF" fill-opacity="0.72" d="{d_tag}"/>
</svg>
"""


def write(rel, text):
    path = os.path.join(ASSETS, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    print("wrote", os.path.relpath(path, os.path.dirname(ASSETS)))


if __name__ == "__main__":
    write("AppIcon.svg", icon_svg())
    write("AppIcon-small.svg", icon_svg(detail=False))
    write("MenuBarIcon.svg", menubar_svg())
    write("brand/wordmark.svg", wordmark_svg())
    write("brand/og-image.svg", og_svg())
