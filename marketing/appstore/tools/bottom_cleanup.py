"""Minimal bottom-edge cleanup for CoreCredit App Store screenshots.

A live capture catches the *next* list row half-scrolled under the floating tab
bar: a ghosted title, price, subtitle, chevron and status pill bleeding out from
behind the bar. This module removes only that ghosted content and rebuilds the
scroll background underneath it, so the shot reads as the same real screen
captured a moment earlier.

Nothing else is touched. The tab bar keeps every one of its own pixels
(including whatever shows through its translucent material), the last full row
and its separator keep theirs, and the bar's drop shadow survives, because the
repair paints back a smooth estimate of the very field the shadow lives in.
"""

from PIL import Image
import numpy as np
from scipy import ndimage

SEPARATOR_Y = 1846      # first row below the last full row's divider
GHOST_THRESHOLD = 3.5   # levels of local deviation that count as ghosted content
PILL_GUARD = 2         # px covering the bar's own anti-aliased edge, left untouched
NEUTRAL_MAX = 4         # B-R above this is page background, at or below is the bar


def _pill_mask(band):
    """The floating tab bar.

    The bar is a neutral material (B and R within a couple of levels) while the
    page behind it is distinctly blue-tinted, which separates the two far more
    reliably than brightness does -- the bar's top edge sits on near-white list
    background and has almost no brightness contrast at all.
    """
    neutral = (band[..., 2] - band[..., 0]) <= NEUTRAL_MAX
    neutral = ndimage.binary_closing(neutral, np.ones((7, 7)))
    lab, n = ndimage.label(neutral)
    if n == 0:
        return np.zeros(band.shape[:2], bool)
    sizes = ndimage.sum(neutral, lab, range(1, n + 1))
    blob = ndimage.binary_fill_holes(lab == (int(np.argmax(sizes)) + 1))
    return _solid_span(blob)


def _solid_span(blob):
    """Trim the component down to the bar itself.

    On screens whose list sits on a white card, the card is neutral too and can
    join the bar through whatever shows past its edge. The bar is a filled pill,
    so every one of its rows is a single unbroken run, while the content joined
    to it breaks into several -- keep the longest stretch of unbroken rows.
    """
    solid = np.zeros(blob.shape[0], bool)
    for y in range(blob.shape[0]):
        xs = np.nonzero(blob[y])[0]
        solid[y] = len(xs) > 0 and len(xs) == xs.max() - xs.min() + 1
    best = span = None
    start = None
    for y in range(len(solid) + 1):
        if y < len(solid) and solid[y]:
            start = y if start is None else start
        elif start is not None:
            if span is None or y - start > span:
                best, span = (start, y), y - start
            start = None
    out = np.zeros_like(blob)
    if best:
        out[best[0]:best[1]] = blob[best[0]:best[1]]
    return out


def _plate(band, exclude):
    """A smooth estimate of the scroll background under `exclude`."""
    _, (iy, ix) = ndimage.distance_transform_edt(exclude, return_indices=True)
    filled = band[iy, ix]
    plate = np.stack([ndimage.median_filter(filled[..., k], size=21)
                      for k in range(3)], axis=-1)
    return ndimage.gaussian_filter(plate, sigma=(5, 5, 0))


def clean(src_png, out_png):
    img = np.array(Image.open(src_png).convert("RGB")).astype(float)
    band = img[SEPARATOR_Y:].copy()

    pill = _pill_mask(band)
    guard = ndimage.binary_dilation(pill, iterations=PILL_GUARD)

    # Smooth reference for the scroll background. The tab bar is lifted out
    # first -- each of its pixels replaced by its nearest neighbour from
    # outside -- so its hard edge cannot masquerade as ghosted content, and none
    # of its white can leak into the repair.
    plate = _plate(band, guard)

    ghost = (np.abs(band - plate).mean(2) > GHOST_THRESHOLD) & ~guard
    # Close the detection into whole objects. A ghosted status pill is a crisp
    # outline around a fill only a couple of levels off the background: repair
    # the outline alone and that fill is left behind as a faint rectangle, so
    # each run of glyphs and each pill is repaired as one solid region.
    ghost = ndimage.binary_closing(ghost, np.ones((29, 29)))
    ghost = ndimage.binary_fill_holes(ghost) & ~guard

    # Second pass: rebuild the reference with the ghosting itself excluded, so
    # the background painted back carries none of what is being removed.
    plate = _plate(band, guard | ghost)

    # Fully opaque across the ghosting, feathered only on its outer edge --
    # `plate` and `band` already agree to within a level or two out there.
    alpha = ndimage.gaussian_filter(
        (ndimage.binary_dilation(ghost, iterations=4) & ~guard).astype(float),
        sigma=2.5)
    alpha = (alpha * ~guard)[..., None]   # the bar keeps every one of its pixels
    band = band * (1 - alpha) + plate * alpha

    img[SEPARATOR_Y:] = band
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out_png)
    return {"ghost_px": int(ghost.sum()), "band_top": SEPARATOR_Y,
            "tab_bar_px": int(pill.sum())}

