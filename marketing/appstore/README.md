# App Store screenshots

Everything here is derived from assets committed at the repository root. The
builds read only those and write only new files — no source capture and no
template layer is ever modified.

## Assets

| File | Role |
| --- | --- |
| `Dashboard.png`, `Cores.png` | raw device captures, 946 × 2048 (**sources — do not edit**) |
| `lefttiltedphone.PNG`, `rightherophone.PNG` | raw `Scan core` / `Add core` captures, 946 × 2048 (**sources — do not edit**) |
| `CoreCredit_AppStore_03_Refined_Background.png` | Image 3 gradient, copy, device body, shadow (**template**) |
| `CoreCredit_AppStore_03_Refined_Device_Overlay.png` | Image 3 frame, highlights, buttons; transparent over the screen (**template**) |
| `CoreCredit_AppStore_03_Refined_Template.png` | Image 3 template preview with the placeholder screen (**template**) |
| `Dashboard_Marketing.png`, `Cores_Marketing.png` | the captures with the marketing status bar and the bottom-edge cleanup (**generated**) |
| `lefttiltedphone_Marketing.png`, `rightherophone_Marketing.png` | the sheet captures with the top edge repaired and the marketing status bar (**generated**) |
| `CoreCredit_AppStore_02_Refined_Background.png` | Image 2 gradient and copy, no devices (**generated**) |
| `CoreCredit_AppStore_02_Refined_Template.png` | Image 2 template preview with placeholder screens (**generated**) |
| `CoreCredit_AppStore_02_Capture_A_Core.png` | finished Image 2, 1290 × 2796 (**generated**) |
| `CoreCredit_AppStore_03_Track_Every_Core.png` | finished Image 3, 1290 × 2796 (**generated**) |

## Build

```sh
python3 marketing/appstore/tools/build.py      # Image 3, from the repository root
python3 marketing/appstore/tools/build2.py     # Image 2
```

Needs Pillow, NumPy and SciPy. Each prints a JSON report of every measurement it
made — scale factor, crop, aperture, pixels repaired, fit residuals — so a
rebuild can be checked against the numbers in the commit that introduced it.
Both builds are deterministic: re-running reproduces every output byte for byte.

## Image 3 — "Track every core at a glance."

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

### Image 3 numbers

Aperture 692, 312, 2167 px tall; 598 px of it on canvas. Screenshot 946 × 2048
scaled ×1.058105 to 1001 × 2167 — the same factor on both axes, so nothing is
stretched. Nothing is cropped vertically; 403 px (40.3 %) of the width falls off
the right edge, which is the template's intended device crop.

## Image 2 — "Capture a core in seconds."

A double-phone composition: the tilted rear phone carries the scan, the larger
upright hero phone in front carries the filled-in Add core screen ready to save.
Image 2 has no template layers of its own to composite into — Image 3's overlay
is a single cropped phone — so the backdrop, the type and the device frame are
each **measured off Image 3 and rebuilt**, rather than redesigned. Every constant
below is a fit against the committed Image 3 layers, and each module reports its
residual so a build can prove it still matches.

1. **`sheet_cleanup.py` — the sheet-presentation top edge.**
   `Scan core` and `Add core` are sheets, so both captures carry a dimmed
   status-bar band, rounded sheet corners cutting into it, and content behind:
   the stacked sheet's edge on one, a blurred card scrolled under the nav bar on
   the other. Everything above the nav bar is rebuilt out of the sheet's own
   background plus the Cancel pill's own drop shadow, whose radial profile is
   measured from a clean stretch of that shadow. `Scan core` is a *stacked*
   sheet and sits 24 px lower, so it is lifted by 24 px and both nav bars line
   up. Then the gallery's marketing status bar is transplanted from
   `Dashboard_Marketing.png` row for row — same icon weight, spacing, alignment
   and vertical placement — and re-seated on the sheet's background, which
   differs from the reference's by at most three levels. The scan phone keeps
   its green camera-privacy dot; nothing else about either app screen changes.

2. **`backdrop.py` — the shared blue field.**
   A vertical ramp read column by column off Image 3's background layer, plus
   one broad glow fitted to every pixel that layer leaves uncovered. The fit
   reproduces those pixels to about 1 level RMS, inside the layer's own dither,
   and is then continued across the whole canvas. Output is dithered with a 4 × 4
   ordered matrix at the amplitude Image 3 itself carries, so a gradient this
   shallow does not band.

3. **`copydeck.py` — the headline and subtitle.**
   Inter ExtraBold 124 / −4.5 tracking / 120 leading in pure white, over Inter
   Medium 45 / 58 leading at 0.894 — every value recovered from Image 3's own
   copy, both blocks optically aligned on their ink. `verify()` re-sets Image 3's
   copy with these numbers against its own backdrop so a build can check the
   typesetting has not drifted.

4. **`device.py` — the device frame.**
   Outline is a superellipse-cornered rect fitted to the Image 3 overlay's alpha
   (R = 0.1463 W, exponent 2.321, matching to about a pixel); bezel 41.5/1000 of
   the screen width; rim and body colours sampled off the template preview and
   modulated by how side-on the edge is, which is what makes a left rail read
   bright against a nearly black top edge; button spans are the overlay's own
   protrusions. Lengths are fractions of the screen width, so a frame at any size
   is the same device. Frames are drawn at ×3 and rotated as one piece, so the
   tilted phone is a uniform rotation — never a stretch. Shadows are a blurred,
   offset silhouette multiplying the canvas, fitted to the darkening Image 3's
   background layer carries around its own device.

5. **`image2.py` — the composition.**
   The only thing decided here rather than measured: where the two phones go.
   Composited back to front, so the hero phone's shadow falls across the rear one.

### Image 2 numbers

Canvas 1290 × 2796. Headline baselines 420 and 540, subtitle 630, ink flush at
x = 99 / 97. Rear phone screen 620 × 1344 px tilted −5.5°, front phone screen
760 × 1647 px upright; both captures scaled uniformly by the aperture height
(×0.656 and ×0.804), so nothing is stretched, and each loses 1 px off the right
to the 0.1 % difference between the capture's aspect and the screen's. The rear
phone is about half covered by the hero, which keeps the scan card, the
photographed label and its barcode visible.
