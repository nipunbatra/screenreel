#!/usr/bin/env python3
"""Generate Screen Reel's editable SVG sources (Python standard library only).

Run this for vector changes; Scripts/make-icons.sh separately builds the
Dock icon, menu-bar PNGs, favicon and social card. Neither opens a window.
"""
from pathlib import Path
from html import escape

ASSETS = Path(__file__).resolve().parent.parent
WEB = ASSETS.parent / "website" / "assets"
INK = "#292C26"
PAPER = "#F7F5EF"
CLAY = "#CC6247"

# A continuous ribbon with open counters. The folded S remains recognizable
# without the old pane marks, glows and inset stripes. One silhouette from
# the menu bar to the Dock; round ends balance its two opposing turns.
RIBBON = "M706 300H406a106 106 0 0 0 0 212h212a106 106 0 0 1 0 212H318"

def ribbon(color=PAPER, width=112):
    return f'<path d="{RIBBON}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>'

def svg(width, height, body, title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" role="img" aria-label="{escape(title)}">\n'
            f'  <title>{escape(title)}</title>\n{body}\n</svg>\n')

def tile():
    return f'<rect x="100" y="100" width="824" height="824" rx="185" fill="{CLAY}"/>\n{ribbon()}'

def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")

def main():
    # Restrained depth on the outer tile only; the ribbon is one flat shape.
    shadow = ('<defs><filter id="shadow" x="-25%" y="-25%" width="150%" height="150%">'
              '<feGaussianBlur stdDeviation="9"/></filter></defs>\n'
              f'<rect x="100" y="111" width="824" height="824" rx="185" fill="{INK}" fill-opacity=".16" filter="url(#shadow)"/>\n')
    write(ASSETS / "AppIcon.svg", svg(1024, 1024, shadow + tile(), "Screen Reel app icon"))
    write(ASSETS / "AppIcon-small.svg", svg(1024, 1024, tile(), "Screen Reel app icon, small"))
    # Black is required for a native template image: AppKit supplies tint.
    menu = f'<g transform="translate(-4.31 -4.31) scale(.026) ">{ribbon("#000000", 116)}</g>'
    write(ASSETS / "MenuBarIcon.svg", svg(18, 18, menu, "Screen Reel menu bar"))
    mark = f'<rect width="64" height="64" rx="14" fill="{CLAY}"/><g transform="translate(-7.77 -7.77) scale(.07767)">{ribbon()}</g>'
    write(WEB / "mark.svg", svg(64, 64, mark, "Screen Reel"))
    # Native font fallbacks keep this generator dependency-free. The app
    # name is text, editable independently of the hand-drawn ribbon.
    font = 'font-family="Avenir Next, Helvetica Neue, Arial, sans-serif"'
    wordmark = f'<g transform="scale(.13)">{tile()}</g><text x="153" y="88" {font} font-size="64" font-weight="500" letter-spacing="-2.7" fill="{INK}">Screen Reel</text>'
    write(ASSETS / "brand" / "wordmark.svg", svg(535, 134, wordmark, "Screen Reel wordmark"))
    social = (f'<rect width="1200" height="630" fill="{PAPER}"/>'
              f'<g transform="translate(65 77) scale(.12)">{tile()}</g>'
              f'<text x="208" y="158" {font} font-size="47" font-weight="500" letter-spacing="-2" fill="{INK}">Screen Reel</text>'
              f'<text x="80" y="306" {font} font-size="81" font-weight="500" letter-spacing="-4" fill="{INK}">Record clearly.</text>'
              f'<text x="80" y="397" {font} font-size="81" font-weight="500" letter-spacing="-4" fill="{CLAY}">Make it yours.</text>'
              f'<path d="M80 490H1120" stroke="#D9D9CE"/>'
              f'<text x="80" y="539" {font} font-size="21" fill="#62665C">Native Mac recording. Open by design.</text>'
              f'<g transform="translate(792 132) scale(.33)">{tile()}</g>')
    write(ASSETS / "brand" / "og-image.svg", svg(1200, 630, social, "Screen Reel. Record clearly. Make it yours."))
    print("Updated six SVG sources; raster regeneration is a separate step.")

if __name__ == "__main__":
    main()
