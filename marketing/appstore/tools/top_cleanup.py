"""Top-of-screen cleanup for CoreCredit App Store screenshots.

A live capture taken part-way down a list catches the *previous* section
half-scrolled under the translucent navigation bar: on the Returns screen that
is a blurred blue "Create return batch" button and a ghosted row caption, with
the collapsed nav title sitting on top of them. It also catches the nav bar's
drop shadow spilling onto the content below.

This module removes only that -- the blurred scroll-under content and the
shadow it casts -- and rebuilds the navigation background underneath, so the
shot reads as the same real screen captured with the list at rest. The nav
title keeps its own pixels: it is lifted out with its anti-aliased coverage
intact and set back down on the rebuilt background at exactly the same place.

Nothing else is touched. Every list row, every amount, every reference and the
whole tab bar are left as captured.
"""

from PIL import Image
import numpy as np
from scipy import ndimage

# --- measured from image4.PNG (the Returns capture) -------------------------
NAV_END = 208           # first row clear of the blurred scroll-under content
FEATHER = 10            # rows over which the rebuilt band eases into the capture
SHADOW_END = 340        # first row clear of the nav bar's drop shadow
MARGIN = 40             # px of page background outside the cards, either side
TITLE_BOX = (388, 144, 558, 192)    # x0, y0, x1, y1 around the collapsed title
TITLE_INK = np.array([58, 58, 58], dtype=float)     # the title's own ink, measured


def _page_background(img):
    """The scroll background, measured where nothing is drawn over it."""
    band = np.concatenate([img[SHADOW_END:SHADOW_END + 120, :MARGIN],
                           img[SHADOW_END:SHADOW_END + 120, -MARGIN:]], axis=1)
    return np.median(band.reshape(-1, 3), axis=0)


def _margin_profile(img, rows):
    """Per-row background colour, read from the margins outside the cards."""
    left = img[rows, :MARGIN]
    right = img[rows, -MARGIN:]
    prof = np.median(np.concatenate([left, right], axis=1), axis=1)
    return ndimage.gaussian_filter1d(prof, sigma=3.0, axis=0)


def _title_coverage(img, plate, reach):
    """Per-pixel coverage of the title's ink over whatever it was drawn on.

    Each pixel's colour is projected onto the ramp from the background it was
    drawn on to the ink, which recovers the anti-aliased edges over the blurred
    button as faithfully as over the flat background beside it. `reach` bounds
    the result to the glyphs and their rim, so nothing the blur left behind can
    read as a few per cent of ink and print as a haze.
    """
    x0, y0, x1, y1 = TITLE_BOX
    px = img[y0:y1, x0:x1]
    bg = plate[y0:y1, x0:x1]
    d = TITLE_INK - bg
    cov = ((px - bg) * d).sum(-1) / (d * d).sum(-1)
    cov = np.clip(cov, 0.0, 1.0) * reach
    cov[cov < 0.04] = 0.0
    return cov


def clean(src_png, out_png):
    img = np.array(Image.open(src_png).convert("RGB")).astype(float)
    page = _page_background(img)

    # The background the title was drawn on: the capture with the title itself
    # lifted out and replaced by its surroundings, then smoothed. Recovering the
    # title's coverage against this rather than against a flat colour is what
    # keeps its anti-aliased edges honest over the blurred button behind it.
    x0, y0, x1, y1 = TITLE_BOX
    box = img[y0:y1, x0:x1]
    ink = np.abs(box - TITLE_INK).sum(-1) < 250      # solidly the title's ink
    reach = ndimage.binary_dilation(ink, np.ones((3, 3)), iterations=4).astype(float)
    lift = ndimage.binary_dilation(ink, np.ones((3, 3)), iterations=5)
    _, (iy, ix) = ndimage.distance_transform_edt(lift, return_indices=True)
    plate = np.zeros_like(img)
    plate[y0:y1, x0:x1] = ndimage.gaussian_filter(box[iy, ix], sigma=(3, 3, 0))
    cov = _title_coverage(img, plate, reach)

    # 1. Cancel the nav bar's drop shadow. It is uniform across the width -- the
    #    margins and the card interiors darken together -- so the correction is
    #    a single colour per row, measured where the page background is bare.
    rows = np.arange(0, SHADOW_END)
    delta = page - _margin_profile(img, rows)
    taper = np.clip((SHADOW_END - rows) / float(SHADOW_END - NAV_END), 0.0, 1.0)
    taper = taper * taper * (3 - 2 * taper)          # smoothstep, so no edge shows
    img[:SHADOW_END] += (delta * taper[:, None])[:, None, :]

    # 2. Rebuild the navigation band. Everything the blur carried goes; the
    #    background it sat on is what the bar shows with the list at rest.
    rebuilt = np.broadcast_to(page, (NAV_END, img.shape[1], 3)).copy()
    ramp = np.clip((np.arange(NAV_END) - (NAV_END - FEATHER)) / float(FEATHER), 0, 1)
    img[:NAV_END] = (rebuilt * (1 - ramp[:, None, None])
                     + img[:NAV_END] * ramp[:, None, None])

    # 3. Set the title back down on the rebuilt background.
    box = img[y0:y1, x0:x1]
    img[y0:y1, x0:x1] = box * (1 - cov[..., None]) + TITLE_INK * cov[..., None]

    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out_png)
    return {"page_background": [round(v, 1) for v in page],
            "nav_band": [0, NAV_END], "shadow_end": SHADOW_END,
            "title_box": TITLE_BOX, "title_ink_px": int((cov > 0.5).sum())}
