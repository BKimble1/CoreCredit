# iPad App Store screenshots

Four finished 2752 × 2064 landscape images for the iPad listing, plus the six
blank templates they are built on.

## Finished images

| File | Headline | Capture |
| --- | --- | --- |
| `CoreCredit_iPad_AppStore_01_dashboard.png` | See your full core-credit picture. | `screenshots/IMG_0309.PNG` |
| `CoreCredit_iPad_AppStore_02_cores.png` | Every core. One reconciled workspace. | `screenshots/IMG_0313.PNG` |
| `CoreCredit_iPad_AppStore_03_returns.png` | Keep returns moving. | `screenshots/IMG_0314.PNG` |
| `CoreCredit_iPad_AppStore_04_timeline.png` | Follow every step to credit. | `screenshots/IMG_0315.PNG` |

## Blank templates

`CoreCredit_iPad_01_*.png` … `CoreCredit_iPad_06_*.png` carry the same
background, device and type scale with the display left as a flat `#F1F5FA`
aperture, for laying a capture in by hand. `template-spec.json` holds the
geometry in machine-readable form.

## Geometry

| | value |
| --- | --- |
| Canvas | 2752 × 2064 |
| Aperture position | x **1116**, y **509** |
| Aperture size | **1475 × 1025** |
| Aperture aspect | 1475 : 1025 — exactly **2360 : 1640** |
| Corner radius | 35 px |

The aperture matches the aspect of the captures this app produces, so a capture
goes in at a single uniform **×0.625** on both axes: nothing stretched, nothing
cropped, no letterboxing. A 4:3 aperture — the 13-inch iPad Pro's shape — would
have forced a centre crop that destroyed 67 columns of the sidebar on the left
and up to 87 of the row chevrons on the right, so the device is drawn at the
captures' own 59:41 instead.

## Cleanup applied to the captures

The raw captures are committed under `screenshots/` and are never modified. Every
repair either rebuilds a background that is already flat or moves pixels that
exist in the captures themselves — no app UI is redrawn and no data is invented.

1. **One status bar across all four.** The captures were taken minutes apart, so
   their clocks read 6:32, 6:34, 6:35 and 6:36. All four are rewritten to
   **9:41** using digit glyphs lifted from the captures' own status bars — the
   `4` from the 6:34 capture, the `9` and `1` out of the `91%` battery readout —
   so the ink is genuine SF Pro at the right size, weight and baseline rather
   than a substituted font. The clock uses tabular figures (the minute digit
   changes across the four without shifting `PM` by a pixel), so the glyphs drop
   into fixed cells. `PM  Wed Aug 19` is copied wholesale as well: the captures
   place it up to a pixel apart, which would read as four subtly different
   status bars. Battery and Wi-Fi are already identical and are left alone.

2. **Returns — the half-scrolled card header.** The vendor header was caught
   under the frosted nav bar, ghosting `Tri-state Parts / $72.00 / 1 core ready`
   through it. The band is rebuilt as a per-column vertical blend between the
   clean rows above and below, so the bar's frosted-to-white fade and the card's
   own edges are reproduced rather than flattened. The `Returns` title sits
   inside that band and is lifted out and re-applied as a delta over the rebuilt
   background, so it keeps its antialiasing and shows no patch.

3. **Alternator — the `Delete core` ghost.** A blurred red menu item was
   bleeding through the nav bar above the title, across rows 24-77. Only rows up
   to about 52 are perfectly flat; below that the bar carries a fine dither, so
   the band is rebuilt by copying clean pixels from the *same rows* further
   along the bar. A per-row median would have been perfectly smooth and read as
   a hole punched in that texture with visible ends, which is what an earlier
   revision did; copying real pixels keeps both the row background and the
   grain, and a discontinuity in noise is invisible.

   The back button is left exactly where the app puts it. Giving it more
   breathing room means moving it, and it cannot be moved without leaving a
   seam: only ~40px separate the sidebar card's edge from the button, and that
   gap is a shadow gully both of them cast into. Every candidate boundary for a
   shifted region except the top and the right sits in non-flat pixels — the
   gully on the left, the History card below — and a radial blend wide enough to
   cover the button's old position drags the sidebar card's bright edge into the
   dark gully. An earlier revision did move it and carried a rectangle of erased
   shadow with it, which showed as hard edges beside the button.

Everything else is untouched: sidebar selection, search bar, Filters chip, the
varied status rows, the open-returns and waiting-on-credit sections, and the
full history timeline are all exactly as captured.

## Rebuilding

```sh
node marketing/appstore/tools/ipad/build.mjs marketing/appstore/ipad   # templates + plates
python3 marketing/appstore/tools/ipad/finish.py                        # clean + compose
```

`build.mjs` needs Playwright with Chromium; `finish.py` needs Pillow and NumPy.
The build embeds the three Inter weights it uses, so it needs no network and
reproduces the same pixels. It measures every authored headline line against its
column and fails if one would overrun it or reach the device. `finish.py`
refuses to run if a capture is not the size the aperture expects, or if the
uniform scale would not land exactly on the aperture — the guard against a
stretched or cropped screenshot slipping through.

The device chrome and shadow are byte-for-byte identical across all four
finished images and the six blank templates.
