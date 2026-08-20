# iPad App Store screenshot templates

Six coordinated 2752 × 2064 landscape templates for the 13-inch iPad Pro
listing. They are **templates, not finished screenshots** — the iPad display is
a flat neutral aperture waiting for a real capture to be laid over it.

| File | Headline |
| --- | --- |
| `CoreCredit_iPad_01_full-picture.png` | See your full core-credit picture. |
| `CoreCredit_iPad_02_capture.png` | Capture a core in seconds. |
| `CoreCredit_iPad_03_workspace.png` | Every core. One organized workspace. |
| `CoreCredit_iPad_04_returns-moving.png` | Keep returns moving. |
| `CoreCredit_iPad_05_still-owed.png` | Know exactly what you’re still owed. |
| `CoreCredit_iPad_06_every-step.png` | Follow every step to credit. |

`template-spec.json` carries the same geometry in machine-readable form.

## Dropping in a real screenshot

The aperture is identical in all six files, so the placement only has to be
worked out once and can then be repeated frame to frame.

| | value |
| --- | --- |
| Canvas | 2752 × 2064 |
| Aperture position | x **1106**, y **461** (from the top-left of the canvas) |
| Aperture size | **1496 × 1122** |
| Aperture aspect | 1496 : 1122 — **exactly 4:3** |
| Corner radius | 38 px |
| Fill | flat `#F1F5FA` |

A native 2752 × 2064 iPad capture is also exactly 4:3, so it scales into the
aperture uniformly — **scale it to 54.36 %** (1496 ÷ 2752) and nothing is
stretched, letterboxed or cropped. Round the corners at 38 px to match the
glass, then the `REPLACE WITH REAL IPAD SCREENSHOT` label underneath is fully
covered.

## Design system

Every file shares one background, one device and one type scale. Only the
headline and the supporting line differ, which is what makes the six read as a
single campaign:

- **Background** — deep navy `#143D84` field with one broad blue glow behind the
  device, so the product is the lit object and the copy column stays a calm,
  even field for white type. Corners fall off to frame the composition.
- **Device** — 13-inch iPad Pro, straight-on with no rotation or perspective.
  Body 1556 × 1182 at x 1076, y 431: right of centre, full device on canvas,
  never cropped. A straight-on device is also the reason a screenshot can be
  dropped in with a plain rectangular scale — a tilted mock-up would need a
  perspective transform for every frame.
- **Shadow** — one broad ambient pool plus one tighter contact shadow, on their
  own layers so the device keeps a crisp edge. Identical in all six.
- **Type** — Inter. Headline 114 px / 800 weight / −0.030 em, supporting line
  48 px / 500 weight, both in an 830 px column at x 172. Headline line breaks
  are authored rather than left to the wrap engine, so they break on sense and
  stay identical on every rebuild.

The device region is byte-for-byte identical across all six files; the build
asserts this.

## Rebuilding

```sh
node marketing/appstore/tools/ipad/build.mjs marketing/appstore/ipad
```

Needs Playwright with Chromium. The script is self-contained — it embeds the
three Inter weights it uses from `tools/ipad/fonts/`, so a rebuild needs no
network and reproduces the same pixels. It prints a measurement report for each
frame (headline line widths against the column, supporting-line count, the
copy block's vertical extent) and fails loudly if any line would overrun the
column or reach the device.

To change copy, edit the `IMAGES` array in `build.mjs` — including the authored
line breaks — and rebuild. To drop the placeholder label from the aperture,
remove the two `ph-` divs.
