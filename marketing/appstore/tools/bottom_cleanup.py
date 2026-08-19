"""Minimal bottom-edge cleanup for CoreCredit App Store screenshots.

A live capture catches the *next* list row half-scrolled under the floating tab
bar: a ghosted title, price, subtitle, chevron and status pill bleeding out from
behind the bar. This module removes only that ghosted content and rebuilds the
scroll background underneath it, so the shot reads as the same real screen
captured a moment earlier.

Nothing else is touched. The tab bar keeps every one of its own pixels, the last
full row and its separator keep theirs, and the bar's drop shadow survives,
because the repair paints back a smooth estimate of the very field the shadow
lives in.

On a screen where the next section is a full-width card, that card lands almost
entirely *behind* the bar and reads through its translucent material as a few
levels of shading in the shape of a title, a price and a caption. `through_bar`
flattens that shading out. The bar's own glyphs and its selected-tab capsule are
left exactly as captured -- they are darker than the material by an order of
magnitude more than the show-through, which is what tells the two apart.
"""

from PIL import Image
import numpy as np
from scipy import ndimage

SEPARATOR_Y = 1846      # first row below the last full row's divider (Image 1/3)
GHOST_THRESHOLD = 3.5   # levels of local deviation that count as ghosted content
PILL_GUARD = 2         # px covering the bar's own anti-aliased edge, left untouched
NEUTRAL_MAX = 4         # B-R above this is page background, at or below is the bar
BAR_RIM = 3             # px of the bar's rim the show-through pass leaves alone
BAR_OWN_MIN = 12        # levels below the material that the selected-tab capsule reaches
BAR_INK_MIN = 45        # levels below the material that only the bar's own ink reaches
BAR_WINDOW = 41         # median width that outlives no stroke the card can print
BELOW_WINDOW = (9, 41)  # ditto under the bar, kept short so the shadow's ramp stays
BELOW_INSET = 40        # px in from the bar's rounded ends, where its shadow is flat


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


def _resurface(band, region, window):
    """Replace `region` with a version of itself that carries no thin detail.

    Each surface in the bar -- the material, the selected-tab capsule -- is a
    flat field in the clean screen, and the card behind prints onto it as
    letterforms whose strokes are far narrower than `window`. A median that wide,
    taken over the surface's own pixels only, keeps the field and drops the
    letters. Nothing outside `region` is read or written, so the bar's icons and
    labels cannot bleed in and are not touched.
    """
    ys, xs = np.nonzero(region)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    sub, mask = band[y0:y1, x0:x1], region[y0:y1, x0:x1]
    _, (iy, ix) = ndimage.distance_transform_edt(~mask, return_indices=True)
    filled = sub[iy, ix]
    flat = np.stack([ndimage.median_filter(filled[..., k], size=window)
                     for k in range(3)], axis=-1)
    flat = ndimage.gaussian_filter(flat, sigma=(2, 2, 0))
    sub[:] = np.where(mask[..., None], flat, sub)


def _flatten_show_through(band, pill):
    """Even out what the card behind the bar leaves showing through it.

    The bar draws its icons and labels an order of magnitude darker than the
    show-through, and its selected-tab capsule is the one large mid-toned shape
    on it, so both separate out cleanly: the icons and labels by threshold, the
    capsule because it survives an opening that thin letterforms do not. What is
    left is the bar's own flat material, and the capsule's, each resurfaced from
    its own pixels. The bar's rim keeps every pixel it was captured with.
    """
    inner = ndimage.binary_erosion(pill, iterations=BAR_RIM)
    if not inner.any():
        return 0
    depth = (np.median(band[inner], axis=0) - band).max(axis=-1)
    drawn = ndimage.binary_dilation(depth > BAR_INK_MIN, iterations=4) & inner
    # The capsule is the one mid-toned shape wide enough to survive an opening
    # that no letterform does; grown back through the mid-toned pixels it seeds,
    # it recovers its own rounded outline rather than the opening's corners.
    mid = (depth > BAR_OWN_MIN) & inner
    capsule = ndimage.binary_propagation(
        ndimage.binary_opening(mid, np.ones((15, 15))), mask=mid)

    material = inner & ~ndimage.binary_dilation(capsule, iterations=3) & ~drawn
    _resurface(band, material, BAR_WINDOW)
    capsule = capsule & ~drawn
    if capsule.sum() > BAR_WINDOW ** 2:
        _resurface(band, capsule, BAR_WINDOW)

    # The same card prints its caption into the strip just under the bar, inside
    # the guard the repair above leaves around the bar's edge. That strip is the
    # bar's own drop shadow: flat across the width between the rounded ends, and
    # a steady ramp down the height, so a median that is wide but short drops the
    # caption and leaves the ramp.
    ys, xs = np.nonzero(pill)
    below = np.zeros(pill.shape, bool)
    below[ys.max() + 1:, xs.min() + BELOW_INSET:xs.max() - BELOW_INSET] = True
    below &= ~ndimage.binary_dilation(pill, iterations=1)
    if below.any():
        _resurface(band, below, BELOW_WINDOW)
    return int(material.sum() + capsule.sum() + below.sum())


def clean(src_png, out_png, separator_y=SEPARATOR_Y, through_bar=False):
    img = np.array(Image.open(src_png).convert("RGB")).astype(float)
    band = img[separator_y:].copy()

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

    through_px = _flatten_show_through(band, pill) if through_bar else 0

    img[separator_y:] = band
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out_png)
    return {"ghost_px": int(ghost.sum()), "band_top": separator_y,
            "tab_bar_px": int(pill.sum()), "show_through_px": through_px}

