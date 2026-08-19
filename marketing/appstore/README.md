# App Store screenshots

Everything here is derived from assets committed at the repository root. The
build reads only those and writes only new files — no source capture and no
template layer is ever modified.

## Assets

| File | Role |
| --- | --- |
| `Dashboard.png`, `Cores.png` | raw device captures, 946 × 2048 (**sources — do not edit**) |
| `CoreCredit_AppStore_03_Refined_Background.png` | Image 3 gradient, copy, device body, shadow (**template**) |
| `CoreCredit_AppStore_03_Refined_Device_Overlay.png` | Image 3 frame, highlights, buttons; transparent over the screen (**template**) |
| `CoreCredit_AppStore_03_Refined_Template.png` | Image 3 template preview with the placeholder screen (**template**) |
| `Dashboard_Marketing.png`, `Cores_Marketing.png` | the captures with the marketing status bar and the bottom-edge cleanup (**generated**) |
| `CoreCredit_AppStore_03_Track_Every_Core.png` | finished Image 3, 1290 × 2796 (**generated**) |

## Build

```sh
python3 marketing/appstore/tools/build.py     # from the repository root
```

Needs Pillow, NumPy and SciPy. It prints a JSON report of every measurement it
made — scale factor, crop, aperture, pixels repaired — so a rebuild can be
checked against the numbers in the commit that introduced it.

## What the pipeline does

1. **`statusbar.py` — one marketing status bar for the whole gallery.**
   Glyph positions, icon sizes, icon spacing, vertical position, left/right
   margins and the black Light Mode ink are all measured from `Dashboard.png`,
   and the Wi-Fi glyph, signal bars and battery shell are copied out of it pixel
   for pixel rather than redrawn. Only the values that make a capture a
   *marketing* capture are set: 9:41, full cellular bars, 100 % battery. Applied
   identically to every capture, so the gallery reads as one device.

2. **`bottom_cleanup.py` — the half-scrolled next row.**
   A live capture catches the next list row under the floating tab bar. That
   ghosting is detected as local deviation from a smooth estimate of the scroll
   background and repaired against a second estimate that excludes it. The tab
   bar keeps every one of its own pixels, as does everything above the last full
   row's divider.

3. **`compose.py` — the template.**
   The screen aperture is flood-filled out of the overlay's alpha channel, so no
   geometry is eyeballed. The screenshot is scaled uniformly by the aperture's
   height and anchored at its top-left; the phone's intended right-hand crop is
   whatever the canvas edge takes.

## Image 3 numbers

Aperture 692, 312, 2167 px tall; 598 px of it on canvas. Screenshot 946 × 2048
scaled ×1.058105 to 1001 × 2167 — the same factor on both axes, so nothing is
stretched. Nothing is cropped vertically; 403 px (40.3 %) of the width falls off
the right edge, which is the template's intended device crop.
