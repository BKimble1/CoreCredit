"""Minimal bottom-edge cleanup for CoreCredit App Store screenshots.

A live capture catches the *next* list row half-scrolled under the floating tab
bar: a ghosted title, price, subtitle, chevron and status pill bleeding out from
behind the bar. This module removes only that ghosted content and rebuilds the
scroll background underneath it, so the shot reads as the same real screen
captured a moment earlier.

Nothing above the last full row's divider is touched, and neither is the bar's
own design -- its material, shape, shadow, icons, labels and selected chip all
keep their pixels. The bar's drop shadow survives too, because the repair paints
back a smooth estimate of the very field the shadow lives in.

`refine_tab_bar` extends the same idea to the bar itself. The bar is a
translucent material, so the row scrolled under it also shows *through* it; that
pass flattens the material back to its own smooth field, which is what it looks
like with nothing behind it, and cleans the slivers of ghosting that hug its
outer edge. Only the material is rebuilt -- every mark the bar draws is masked
out of the repair and comes through untouched.
"""

from PIL import Image
import numpy as np
from scipy import ndimage

SEPARATOR_Y = 1846      # first row below the last full row's divider
GHOST_THRESHOLD = 3.5   # levels of local deviation that count as ghosted content
PILL_GUARD = 2          # px covering the bar's own anti-aliased edge, left untouched
NEUTRAL_MAX = 4         # B-R above this is page background, at or below is the bar

BAR_RIM = 4             # px of the bar's own edge highlight left untouched
BAR_INK = 215           # luminance below this inside the bar is a mark the bar draws
BAR_INK_GUARD = 4       # px around those marks left untouched
CHIP_GUARD = 5          # px around the selected tab's chip edge left untouched
COLLAR_DARK = 6         # levels darker than the background: ghosting, never the bar


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


def clean(src_png, out_png, refine_tab_bar=False):
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

    # Feathered so the repaired patches have no edge of their own; `plate` and
    # `band` already agree to within a level or two outside the ghosting.
    alpha = ndimage.gaussian_filter(
        (ndimage.binary_dilation(ghost, iterations=4) & ~guard).astype(float),
        sigma=2.5)
    if refine_tab_bar:
        # Full strength wherever ghosting was actually found. Otherwise the
        # feather, cut off at the bar's edge, half-repairs the strokes that run
        # right up against it and leaves them as tick marks along the bar.
        alpha = np.maximum(alpha, ghost.astype(float))
    alpha = (alpha * ~guard)[..., None]   # the bar keeps every one of its pixels
    band = band * (1 - alpha) + plate * alpha

    stats = {"ghost_px": int(ghost.sum()), "band_top": SEPARATOR_Y,
             "tab_bar_px": int(pill.sum())}
    if refine_tab_bar:
        band, collar_px = _clean_collar(band, pill, guard, plate)
        band, flat_px = _flatten_bar(band, pill)
        stats["collar_px"] = collar_px
        stats["bar_material_px"] = flat_px

    img[SEPARATOR_Y:] = band
    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out_png)
    return stats


def _clean_collar(band, pill, guard, plate):
    """Clear ghosting from the couple of pixels hugging the bar's outer edge.

    That collar is held back from the main repair so the bar's anti-aliased edge
    survives it. The bar is always lighter than the page behind it, so anything
    in the collar that is *darker* than the background can only be the row
    scrolled underneath, never the bar.
    """
    collar = guard & ~pill
    dark = collar & ((plate - band).mean(2) > COLLAR_DARK)
    out = np.where(dark[..., None], plate, band)
    return out, int(dark.sum())


def _flatten_bar(band, pill):
    """Flatten the bar's translucent material back to its own smooth field.

    The material carries a blurred image of whatever is behind it, which on a
    scrolled list is the next row. Everything the bar itself draws -- its edge
    highlight, its icons and labels, the selected tab's chip and that chip's
    edge -- is masked out and passes through untouched; only the material
    between those marks is rebuilt.
    """
    lum = band.mean(2)
    ink = ndimage.binary_dilation((lum < BAR_INK) & pill, iterations=BAR_INK_GUARD)
    rim = ndimage.binary_erosion(pill, iterations=BAR_RIM)

    material = np.median(band[pill & ~ink], axis=0)
    chip = (np.abs(band - material).sum(2) > 24) & pill & ~ink
    chip = ndimage.binary_closing(chip, np.ones((9, 9)))
    lab, n = ndimage.label(chip)
    if n:
        sizes = ndimage.sum(chip, lab, range(1, n + 1))
        chip = ndimage.binary_fill_holes(lab == (int(np.argmax(sizes)) + 1))
        edge = (ndimage.binary_dilation(chip, iterations=CHIP_GUARD)
                & ~ndimage.binary_erosion(chip, iterations=CHIP_GUARD))
    else:
        edge = np.zeros_like(pill)

    flat = rim & ~ink & ~edge
    _, (iy, ix) = ndimage.distance_transform_edt((~pill) | ink, return_indices=True)
    filled = band[iy, ix]
    smooth = np.stack([ndimage.median_filter(filled[..., k], size=25)
                       for k in range(3)], axis=-1)
    smooth = ndimage.gaussian_filter(smooth, sigma=(1.5, 1.5, 0))
    out = np.where(flat[..., None], smooth, band)
    return out, int(flat.sum())

