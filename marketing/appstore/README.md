# App Store screenshots

Everything here is derived from assets committed at the repository root. The
build reads only those and writes only new files — no source capture and no
template layer is ever modified.

## Assets

| File | Role |
| --- | --- |
| `Dashboard.png`, `Cores.png`, `image4.PNG` | raw device captures, 946 × 2048 (**sources — do not edit**) |
| `CoreCredit_AppStore_0N_Refined_Background.png` | image N's gradient, copy, device body, shadow (**template**) |
| `CoreCredit_AppStore_0N_Refined_Device_Overlay.png` | image N's frame, highlights, buttons; transparent over the screen (**template**) |
| `CoreCredit_AppStore_0N_Refined_Template.png` | image N's template preview with the placeholder screen (**template**) |
| `Dashboard_Marketing.png`, `Cores_Marketing.png`, `Returns_Marketing.png` | the captures with the marketing status bar and the edge cleanups (**generated**) |
| `CoreCredit_AppStore_03_Track_Every_Core.png` | finished Image 3, 1290 × 2796 (**generated**) |
| `CoreCredit_AppStore_04_Track_Every_Step.png` | finished Image 4, 1290 × 2796 (**generated**) |

## Build

```sh
python3 marketing/appstore/tools/build.py     # from the repository root
```

Needs Pillow, NumPy and SciPy. It prints a JSON report of every measurement it
made — scale factor, crop, aperture, pixels repaired — so a rebuild can be
checked against the numbers in the commit that introduced it. Rebuilding is
byte-for-byte reproducible: every generated file already in the repository comes
back identical.

## What the pipeline does

1. **`statusbar.py` — one marketing status bar for the whole gallery.**
   Glyph positions, icon sizes, icon spacing, vertical position, left/right
   margins and the black Light Mode ink are all measured from `Dashboard.png`,
   and the Wi-Fi glyph, signal bars and battery shell are copied out of it pixel
   for pixel rather than redrawn. Only the values that make a capture a
   *marketing* capture are set: 9:41, full cellular bars, 100 % battery. Applied
   identically to every capture, so the gallery reads as one device.

2. **`top_cleanup.py` — the half-scrolled previous section.**
   A capture taken part-way down a list also catches the section *above* it,
   blurred under the translucent navigation bar, and the shadow that bar casts
   on the content below. Both go: the shadow is cancelled row by row against the
   page background measured in the margins, where nothing is drawn over it, and
   the navigation band is rebuilt as the background the bar shows with the list
   at rest. The collapsed nav title is lifted out with its anti-aliased coverage
   intact and set back down in exactly the same place. Applied to the Returns
   capture, whose previous section is a blurred *Create return batch* button.

3. **`bottom_cleanup.py` — the half-scrolled next row.**
   A live capture catches the next list row under the floating tab bar. That
   ghosting is detected as local deviation from a smooth estimate of the scroll
   background and repaired against a second estimate that excludes it. The tab
   bar keeps every one of its own pixels, as does everything above the last full
   row's divider. Where the next section is a full-width card it lands almost
   entirely *behind* the bar and reads through its material as a few levels of
   shading shaped like a title, a price and a caption; each surface of the bar is
   then resurfaced from its own pixels by a median too wide for any letterform to
   survive, which leaves the bar's icons, labels and selected-tab capsule exactly
   as captured.

4. **`compose.py` — the template.**
   The screen aperture is flood-filled out of the overlay's alpha channel, so no
   geometry is eyeballed. The screenshot is scaled by one factor on both axes,
   the larger of the two the aperture asks for, and anchored at the aperture's
   top-left. That fills the aperture whole and leaves the crop where the template
   put it: Image 3 stands its phone at the right and takes the far side off the
   canvas edge, Image 4 stands it centred and takes the bottom.

5. **`spotlight.py` — the zoom callout.**
   One row is lifted straight out of the marketing capture, enlarged and set back
   down on the composite as a blue-bordered card centred on the row it came from.
   Nothing is redrawn, so the vendor, amount, handoff, date and reference read
   exactly as the app rendered them.

## Numbers

**Image 3.** Aperture 692, 312, 2167 px tall; 598 px of it on canvas. Screenshot
946 × 2048 scaled ×1.058105 to 1001 × 2167 — the same factor on both axes, so
nothing is stretched. Nothing is cropped vertically; 403 px (40.3 %) of the width
falls off the right edge, which is the template's intended device crop.

**Image 4.** Aperture 145, 670, 1000 px wide and 2126 px tall, the phone standing
centred with the canvas taking its bottom. Screenshot 946 × 2048 scaled
×1.057082 to 1000 × 2165 — again one factor on both axes. Nothing is cropped
horizontally. Of the 39 px the height is short, 24 go off the top and 15 off the
bottom: the capture's first 23 rows are a single flat colour, so only status-bar
margin is spent, and what it buys is *Waiting on credit* and the total sitting
clear of the canvas edge with the tab bar's own background under it.

The callout takes the second row under *Open returns* — Fleet line Diesel,
$180.00 — from 41, 975 to 905, 1103 in the capture, enlarges it ×1.1759 (×1.11
against the screen behind it) and sets it at 133–1156, centred on the row at
1665–1823. It clears the ink of the rows either side, and runs 12 px past the
screen onto the black bezel on both sides — far enough to read as a layer above
the device, and still 33 px clear of the gradient, so it stays part of the phone.
