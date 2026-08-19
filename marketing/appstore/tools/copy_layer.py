"""Set a gallery image's marketing copy on the shared CoreCredit template.

The template ships one background layer per gallery image, carrying the blue
gradient, the device body, its shadow and that image's headline and subtitle.
Every image in the gallery uses the same copy block: the same left margin, the
same headline size, weight, tracking and leading, the same subtitle size and
opacity -- only the words change. So a new image's background is the one that
already exists with its words lifted off and the new ones set in their place.

The words come off by fitting the gradient behind them: it is a smooth field, so
a polynomial in x and y fits it to within a level, and the small remainder is
interpolated across the letters from the pixels around them. The words go back
on with the geometry measured from the layer they were lifted from, so the block
lands exactly where the template put it.
"""

from PIL import Image, ImageDraw, ImageFont
import numpy as np
from scipy import ndimage

# --- the copy block, measured from CoreCredit_AppStore_03_Refined_Background ---
PEN_X = 95              # left pen position, shared by both blocks
HEAD_TOP = 621          # pen y of the headline's first line
HEAD_STEP = 120         # headline leading
HEAD_SIZE = 122
HEAD_TRACK = -2.25
HEAD_FONT = "Inter-ExtraBold.ttf"
SUB_TOP = 1146          # pen y of the subtitle's first line
SUB_STEP = 58           # subtitle leading
SUB_SIZE = 46
SUB_TRACK = -0.75
SUB_FONT = "Inter-SemiBold.ttf"
SUB_ALPHA = 0.870       # the subtitle's white, measured off the template
COPY_BOX = (0, 540, 690, 1420)      # x0, y0, x1, y1 enclosing the whole block
TEXT_MIN_RED = 90       # the gradient's red never reaches this; the white copy does
FIT_DEGREE = 7          # polynomial order the gradient is fitted to


def _gradient(win, text):
    """The gradient behind the copy: a polynomial fit plus its own remainder."""
    known = ~ndimage.binary_dilation(text, np.ones((11, 11)))
    h, w = win.shape[:2]
    yy, xx = np.mgrid[0:h, 0:w]
    yn, xn = (yy / h) * 2 - 1, (xx / w) * 2 - 1
    terms = [(yn ** i) * (xn ** j)
             for i in range(FIT_DEGREE + 1) for j in range(FIT_DEGREE + 1 - i)]
    basis = np.stack([t[known] for t in terms], axis=1)
    out = np.zeros_like(win)
    for k in range(3):
        coef, *_ = np.linalg.lstsq(basis, win[..., k][known], rcond=None)
        fit = sum(c * t for c, t in zip(coef, terms))
        # Whatever the polynomial misses is smooth too, so carry it across the
        # letters from the pixels beside them rather than leaving a faint ghost.
        rest = np.where(known, win[..., k] - fit, 0.0)
        _, (iy, ix) = ndimage.distance_transform_edt(~known, return_indices=True)
        out[..., k] = fit + ndimage.gaussian_filter(rest[iy, ix], sigma=12.0)
    return out


def _set_line(draw, text, font, pen_x, pen_y, track, fill):
    x = float(pen_x)
    for ch in text:
        draw.text((x, pen_y), ch, font=font, fill=fill)
        x += draw.textlength(ch, font=font) + track
    return x - track - pen_x


def set_copy(background_png, headline, subtitle, out_png, font_dir):
    """Write `background_png` with `headline` and `subtitle` in place of its own."""
    img = np.array(Image.open(background_png).convert("RGB")).astype(float)
    x0, y0, x1, y1 = COPY_BOX
    win = img[y0:y1, x0:x1]
    text = win[..., 0] > TEXT_MIN_RED
    img[y0:y1, x0:x1] = _gradient(win, text)

    canvas = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert("RGBA")
    layer = Image.new("RGBA", canvas.size, (255, 255, 255, 0))
    draw = ImageDraw.Draw(layer)
    widths = {"headline": [], "subtitle": []}

    head = ImageFont.truetype(f"{font_dir}/{HEAD_FONT}", HEAD_SIZE)
    for i, line in enumerate(headline):
        widths["headline"].append(round(_set_line(
            draw, line, head, PEN_X, HEAD_TOP + HEAD_STEP * i, HEAD_TRACK,
            (255, 255, 255, 255)), 1))
    sub = ImageFont.truetype(f"{font_dir}/{SUB_FONT}", SUB_SIZE)
    ink = (255, 255, 255, int(round(SUB_ALPHA * 255)))
    for i, line in enumerate(subtitle):
        widths["subtitle"].append(round(_set_line(
            draw, line, sub, PEN_X, SUB_TOP + SUB_STEP * i, SUB_TRACK, ink), 1))

    Image.alpha_composite(canvas, layer).convert("RGB").save(out_png)
    return {"copy_box": COPY_BOX, "lifted_px": int(text.sum()),
            "headline_lines": len(headline), "subtitle_lines": len(subtitle),
            "line_widths": widths}
