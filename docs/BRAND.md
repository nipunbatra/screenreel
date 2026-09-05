# Screen Reel brand

The product name is **Screen Reel**, two words. The shell command is
`screenreel`. Swift module names, the `.screenreel` extension, bundle ID and
storage paths stay stable; legacy `.aks` recordings remain readable.

The mark is a single ribbon folded into an S, set in warm white on a clay
tile. Its open counters and consistent stroke replace the earlier pane
detail, inset stripes and glow. The menu bar uses the same silhouette.

| Token | Color | Use |
|---|---|---|
| Ink | `#292C26` | Text, primary buttons |
| Paper | `#F7F5EF` | Page, ribbon |
| Clay | `#CC6247` | Icon tile |
| Text accent | `#B6442C` | Accessible accent text on paper |

The Dock source has a 1024 px canvas, an 824 px tile at (100,100), and 185 px
corners. The ribbon is a 112 px stroke with 106 px turn radii. Its center
rows are 300, 512 and 724. Small icons omit the tile shadow. The menu bar is
18 pt with black alpha artwork for AppKit template tinting.

The website uses system typography (Avenir Next with platform fallbacks),
no remote fonts or perpetual animation. Motion happens only after an
interaction and respects reduced-motion preferences.

## Sources and builds

```sh
python3 Assets/brand/make-sources.py # writes SVG only; no extra packages
Scripts/make-icons.sh              # regenerate PNGs + ICNS on macOS
```

The generator writes `Assets/AppIcon.svg`, `Assets/AppIcon-small.svg`,
`Assets/MenuBarIcon.svg`, `Assets/brand/wordmark.svg`,
`Assets/brand/og-image.svg`, and `website/assets/mark.svg`.
The raster pipeline remains `Scripts/render-svg.swift` + `iconutil`.

Inspect 16, 32, 128 and 1024 px outputs before shipping. Keep at least half
a ribbon-stroke width clear around the standalone mark. Do not add frame
perforations, multiple accents, glows or details that disappear at menu-bar
size. Wordmarks use the exact spelling **Screen Reel**.

## Current validation checkpoint

The September 5 SVGs, PNGs and ICNS have been regenerated. The 16, 32, 128
and 1024 px icons and 1200×630 social image were visually inspected. The
menu-bar template identity passed the native UX harness. The website was
checked at 1440, 768 and 390 px, including its style controls and privacy page.
