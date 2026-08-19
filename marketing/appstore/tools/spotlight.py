"""App Store zoom callout over a single list row.

One row of the screen is lifted straight out of the marketing capture, enlarged
and set back down on the canvas as a bordered card, centred on the very row it
came from. Nothing is redrawn: the callout is those pixels at a larger scale, so
the vendor, the amount, the handoff, the date and the reference read exactly as
the app rendered them -- including the part of the row the template's device
crop pushes off the canvas.
"""

from PIL import Image, ImageDraw, ImageFilter
import numpy as np

RADIUS = 30             # corner radius of the callout, canvas px
BORDER = 6              # blue rule around it
BORDER_RGB = (0, 64, 196)           # the app's own accent blue, measured
SHADOW_BLUR = 22
SHADOW_OFFSET = 12
SHADOW_ALPHA = 0.30


def _rounded(size, radius, fill, mode="RGBA"):
    card = Image.new(mode, size, 0 if mode == "L" else (0, 0, 0, 0))
    ImageDraw.Draw(card).rounded_rectangle([0, 0, size[0] - 1, size[1] - 1],
                                           radius=radius, fill=fill)
    return card


def place(canvas_png, capture_png, out_png, source, width, right, aperture_top,
          scale):
    """Set a callout of `source` (x0, y0, x1, y1 in the capture) on the canvas.

    `width` is the callout's full width in canvas pixels and `right` its right
    edge; it is centred on the row's own position on the canvas, which the
    template's aperture top and the compositing scale fix exactly.
    """
    canvas = Image.open(canvas_png).convert("RGBA")
    x0, y0, x1, y1 = source
    crop = Image.open(capture_png).convert("RGB").crop(source)

    inner_w = width - 2 * BORDER
    zoom = inner_w / float(x1 - x0)
    inner_h = int(round((y1 - y0) * zoom))
    height = inner_h + 2 * BORDER

    card = _rounded((width, height), RADIUS, BORDER_RGB + (255,))
    inner = crop.resize((inner_w, inner_h), Image.LANCZOS).convert("RGBA")
    inner.putalpha(_rounded((inner_w, inner_h), RADIUS - BORDER, 255, "L"))
    card.alpha_composite(inner, (BORDER, BORDER))

    left = right - width
    top = int(round(aperture_top + (y0 + y1) / 2.0 * scale)) - height // 2

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (width, height),
                           (12, 30, 70, int(round(255 * SHADOW_ALPHA)))),
                 (left, top + SHADOW_OFFSET),
                 _rounded((width, height), RADIUS, 255, "L"))
    canvas = Image.alpha_composite(canvas, shadow.filter(
        ImageFilter.GaussianBlur(SHADOW_BLUR)))

    out = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    out.paste(card, (left, top), card)
    Image.alpha_composite(canvas, out).convert("RGB").save(out_png)

    return {"source": list(source), "zoom": round(zoom, 4),
            "zoom_vs_screen": round(zoom / scale, 4),
            "box": [left, top, left + width, top + height],
            "border": BORDER, "radius": RADIUS}
