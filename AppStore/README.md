# App Store screenshots

## Image3-Cores-1290x2796.png

App Store screenshot 3 (6.7"/6.9" iPhone slot), 1290 × 2796, portrait.

Composed by `scripts/make_app_store_image3.py` from `Cores.png` — the real
device capture of the Cores list, which is the source of truth for the app UI
and is inserted verbatim.

### Composition

| Element | Value |
| --- | --- |
| Canvas | 1290 × 2796 |
| Headline | Track every core at a glance. |
| Subtitle | Stay on top of what's ready, overdue, and still at risk. |
| Screen rect | x 352, y 724, 966 × 2092 |
| Screen aspect | 0.46176 vs. 0.46191 in the source — 0.03% off, so the UI is not stretched |
| Device | right-biased, frame bleeds 52 px past the right edge and off the bottom |

Nothing in the captured UI is cropped: the 28 px of screen that fall past the
right edge of the canvas are empty margin, verified to contain no non-background
pixels.

### The two permitted edits to the capture

1. **Status bar** — the captured `1:20 / 5G / 82%` bar is replaced with the
   standard App Store bar: 9:41, full cellular, Wi-Fi, full battery, drawn in
   black for Light Mode at the capture's own metrics (glyph band y 46–78, clock
   centred on x 155, right cluster ending at x 866).
2. **Bottom edge** — the sixth list row peeking out from behind the floating tab
   bar is removed, both below the bar and where it ghosted through the frosted
   material. The tab bar itself, its selected capsule, its icons and its labels
   are masked out and copied through untouched, and its drop shadow is rebuilt
   on the repainted background.

Everything else — every row, price, status chip, icon, colour and metric — is
the original capture.

### Regenerating

The script needs [Inter](https://github.com/rsms/inter) (Apache-2.0) for the
marketing type and the status-bar clock. Point `INTER_TTF_DIR` at the unzipped
`extras/ttf` directory; it defaults to `/tmp/inter/extras/ttf`.

```sh
pip install Pillow
INTER_TTF_DIR=/path/to/inter/extras/ttf python3 scripts/make_app_store_image3.py
```
