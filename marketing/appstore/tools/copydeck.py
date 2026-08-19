"""The gallery's headline and subtitle, set the way Image 3 sets them.

Face, weight, size, tracking, leading, left margin and ink strength were all
recovered from Image 3's background layer rather than chosen here:

  * headline -- Inter ExtraBold 124, tracked -4.5, 120 px leading, pure white.
    Matched against Image 3's own `Track` at best alignment it scores 0.88 IoU,
    against 0.78 for the nearest other face on this machine.
  * subtitle -- Inter Medium 45, untracked, 58 px leading, white at 0.894.
  * the headline's ink starts at x=99 and the subtitle's at x=97 -- optical
    alignment, which is why Image 3's four headline lines agree to a pixel
    despite starting on T, e, c and a,
  * the subtitle's first baseline is 90 px below the headline's last.

`verify()` re-sets Image 3's own copy with these numbers so a build can prove
the typesetting still matches the layer it was measured from.
"""

from PIL import Image, ImageDraw, ImageFont
import numpy as np
import os

FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")

HEAD_LEFT = 99                  # both blocks are aligned on their ink, not their
SUB_LEFT = 97                   # pens -- which is how Image 3's four lines line up
HEAD_FONT, HEAD_SIZE = "Inter-800.ttf", 124
HEAD_TRACK, HEAD_LEAD = -4.5, 120
SUB_FONT, SUB_SIZE = "Inter-500.ttf", 45
SUB_TRACK, SUB_LEAD = 0.0, 58
SUB_ALPHA = 0.894
BLOCK_GAP = 90                  # headline's last baseline to subtitle's first

# Image 3's own copy, kept so a build can check the typesetting still matches.
REFERENCE = {
    "headline": ["Track", "every", "core at", "a glance."],
    "subtitle": ["Stay on top of what's", "ready, overdue, and", "still at risk."],
    "first_baseline": 740,
}


def _font(name, size):
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def _line_alpha(text, font, track):
    """Coverage for one tracked line, plus its ink offset from the pen origin."""
    pad = 400
    img = Image.new("L", (pad * 2 + 40 * len(text) * font.size // 10, pad), 0)
    d = ImageDraw.Draw(img)
    x = float(pad // 2)
    for ch in text:
        d.text((x, pad // 4), ch, font=font, fill=255)
        x += d.textlength(ch, font=font) + track
    a = np.array(img).astype(float) / 255.0
    ys, xs = np.nonzero(a > 0.004)
    return a[:, xs.min():xs.max() + 1], xs.min() - pad // 2


def measure(text, font_name, size, track):
    font = _font(font_name, size)
    a, _ = _line_alpha(text, font, track)
    ys = np.nonzero((a > 0.5).sum(axis=1))[0]
    return {"width": a.shape[1], "ink_top": int(ys.min()), "ink_bottom": int(ys.max())}


def _baseline_offset(font_name, size, track):
    """Rows from the render's top edge down to the baseline, via a flat-bottom glyph."""
    a, _ = _line_alpha("H", _font(font_name, size), track)
    ys = np.nonzero((a > 0.5).sum(axis=1))[0]
    return int(ys.max()) + 1


def draw(canvas, headline, subtitle, first_baseline):
    """Set both blocks onto the float RGB `canvas`; returns where everything landed."""
    report = {"headline": [], "subtitle": []}

    for block, lines, name, size, track, lead, alpha, left in (
            ("headline", headline, HEAD_FONT, HEAD_SIZE, HEAD_TRACK, HEAD_LEAD, 1.0, HEAD_LEFT),
            ("subtitle", subtitle, SUB_FONT, SUB_SIZE, SUB_TRACK, SUB_LEAD, SUB_ALPHA, SUB_LEFT)):
        if block == "subtitle":
            first_baseline = base_last + BLOCK_GAP
        font = _font(name, size)
        drop = _baseline_offset(name, size, track)
        for i, text in enumerate(lines):
            baseline = first_baseline + i * lead
            a, _ = _line_alpha(text, font, track)
            top, x0 = baseline - drop, left
            h, w = a.shape
            sub = canvas[top:top + h, x0:x0 + w]
            m = (a[:h, :w] * alpha)[..., None]
            canvas[top:top + h, x0:x0 + w] = sub * (1.0 - m) + 255.0 * m
            report[block].append({"text": text, "baseline": baseline,
                                  "x": x0, "width": w})
        base_last = first_baseline + (len(lines) - 1) * lead
    return report


def verify(background_png):
    """Re-set Image 3's copy with these numbers and report the pixel agreement."""
    ref = np.array(Image.open(background_png).convert("RGB")).astype(float)
    canvas = ref.copy()
    box = (600, 1340, 40, 660)
    r0, r1, c0, c1 = box
    # Wipe the reference's own copy, then re-set it over the same backdrop.
    import backdrop
    fit = backdrop.measure(background_png)
    canvas[r0:r1, c0:c1] = backdrop.field(fit)[r0:r1, c0:c1]
    drawn = draw(canvas, REFERENCE["headline"], REFERENCE["subtitle"],
                 REFERENCE["first_baseline"])
    def ink_mask(a):
        loc = a[:, 560:600].mean(axis=1, keepdims=True)
        return np.clip(((a - loc) / (255.0 - loc)).mean(axis=-1), 0, 1) > 0.5
    want, got = ink_mask(ref)[r0:r1, c0:c1], ink_mask(canvas)[r0:r1, c0:c1]
    return {"layout": drawn,
            "ink_iou": round(float((want & got).sum() / (want | got).sum()), 4),
            "ink_px_reference": int(want.sum()), "ink_px_reset": int(got.sum())}
