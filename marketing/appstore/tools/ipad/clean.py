"""
Cleanup pass for the four real iPad captures (2360 x 1640).

Nothing here redraws app UI. Every repair either rebuilds a background that is
already flat, or moves/copies pixels that exist in the captures themselves:

  * the clock is normalised to 9:41 using digit glyphs lifted from the captures'
    own status bars, so the ink is genuine SF Pro at the right size and weight;
  * content ghosting through a translucent bar is replaced with that bar's own
    per-row background;
  * the back button is moved, not redrawn.
"""

import numpy as np
from PIL import Image

SRC = {
    'dashboard':  'IMG_0309.PNG',   # clock reads 6:32
    'cores':      'IMG_0313.PNG',   # 6:34
    'returns':    'IMG_0314.PNG',   # 6:35
    'alternator': 'IMG_0315.PNG',   # 6:36
}

# ---------------------------------------------------------------- helpers --

def row_bg(a, y0, y1, xs):
    """Per-row background colour: the median over a set of clean columns."""
    return np.median(a[y0:y1, xs, :], axis=1)


def bg_field(a, y0, y1, x0, x1, left_xs, right_xs):
    """
    Background estimate for a wide block: per-row samples taken either side of
    it, interpolated horizontally. The status bar's background drifts a couple
    of levels across its width, so a single sample would leave the rebuilt block
    sitting a shade off its surroundings.
    """
    lo = row_bg(a, y0, y1, left_xs)[:, None, :]
    hi = row_bg(a, y0, y1, right_xs)[:, None, :]
    lx = float(np.mean(left_xs))
    t = np.clip((np.arange(x0, x1) - lx) / (float(np.mean(right_xs)) - lx), 0, 1)
    return lo * (1 - t[None, :, None]) + hi * t[None, :, None]


def fill_flat(a, y0, y1, x0, x1, xs, keep=()):
    """
    Replace a rectangle with its own per-row background. `keep` lists boxes that
    must survive untouched — e.g. a title sitting inside the repair band.
    """
    bg = row_bg(a, y0, y1, xs)
    saved = [(b, a[b[1]:b[3], b[0]:b[2], :].copy()) for b in keep]
    a[y0:y1, x0:x1, :] = np.repeat(bg[:, None, :], x1 - x0, axis=1)
    for (bx0, by0, bx1, by1), px in saved:
        a[by0:by1, bx0:bx1, :] = px


def fill_vgrad(a, y0, y1, x0, x1, keep=()):
    """
    Rebuild a band as a per-column vertical blend between the clean rows just
    above and just below it. Because every column is interpolated from its own
    neighbours, card edges and the frosted bar's fade are reproduced rather than
    flattened — which a single rectangular fill cannot do.

    `keep` holds (box, bg_columns) pairs: that ink is lifted as a delta from its
    own background and re-applied over the rebuilt one, so it keeps its
    antialiasing and gains no visible patch.
    """
    saved = []
    for box, bg_xs in keep:
        bx0, by0, bx1, by1 = box
        bg = row_bg(a, by0, by1, bg_xs)
        saved.append((box, bg_xs, a[by0:by1, bx0:bx1, :] - bg[:, None, :]))

    top = a[y0 - 6:y0, x0:x1, :].mean(axis=0)
    bot = a[y1:y1 + 6, x0:x1, :].mean(axis=0)
    t = ((np.arange(y1 - y0) + 0.5) / (y1 - y0))[:, None, None]
    a[y0:y1, x0:x1, :] = top[None] * (1 - t) + bot[None] * t

    for (bx0, by0, bx1, by1), bg_xs, delta in saved:
        bg = row_bg(a, by0, by1, bg_xs)
        a[by0:by1, bx0:bx1, :] = np.clip(bg[:, None, :] + delta, 0, 255)


def paste_delta(dst, src, sy0, sy1, sx0, sx1, tx0, src_xs, dst_xs):
    """
    Copy a glyph as a *difference from its own background*, then re-apply that
    difference over the destination's background. Antialiasing and ink colour
    survive exactly; the surrounding gradient stays the destination's own.
    """
    sbg = row_bg(src, sy0, sy1, src_xs)
    dbg = row_bg(dst, sy0, sy1, dst_xs)
    delta = src[sy0:sy1, sx0:sx1, :].astype(float) - sbg[:, None, :]
    dst[sy0:sy1, tx0:tx0 + (sx1 - sx0), :] = np.clip(dbg[:, None, :] + delta, 0, 255)


# ------------------------------------------------------------- status bar --
# The clock uses tabular figures: across the four captures the minute digit
# changes (2/4/5/6) without shifting "PM" or the date by a pixel. Cells sit on
# an 18px advance with ink centres at 41.0 (hour), 66.5 and 84.5 (minutes).

CLOCK_Y0, CLOCK_Y1 = 16, 52
BLOCK_X0, BLOCK_X1 = 26, 330           # the whole "9:41 PM  Wed Aug 19" run
BG_L = list(range(18, 33))             # clean columns left of the block
BG_R = list(range(336, 430))           # clean columns right of it
BATT_L = list(range(2148, 2168))       # clean columns left of the wifi glyph
BATT_R = list(range(2336, 2352))

# char, source, ink box (x0,x1,y0,y1), that source's bg columns, target ink centre
GLYPHS = [
    ('9', 'dashboard', 2211, 2226, 22, 43, (BATT_L, BATT_R), 41.0),   # from "91%"
    ('4', 'cores',       77,   93, 22, 42, (BG_L, BG_R),     66.5),   # from "6:34"
    ('1', 'dashboard', 2229, 2237, 22, 42, (BATT_L, BATT_R), 84.5),   # from "91%"
]
COLON_X0, COLON_X1 = 49, 60
SUFFIX_X0 = 96                          # "PM  Wed Aug 19" starts here


def normalise_clock(images):
    """
    Rewrite every clock to 9:41, and give all four the same "PM  Wed Aug 19"
    run. Glyph ink is lifted from pristine copies first: two of the sources live
    in images this also rewrites, so reading them lazily would pick up
    already-edited pixels.

    The suffix is copied wholesale because the captures place it up to a pixel
    apart from one another — identical text, different subpixel origin — which
    would read as four subtly different status bars.
    """
    ref = images['dashboard']

    def lift(src, y0, y1, x0, x1, bgs):
        return src[y0:y1, x0:x1, :] - bg_field(src, y0, y1, x0, x1, *bgs)

    blocks = [(COLON_X0, CLOCK_Y0, lift(ref, CLOCK_Y0, CLOCK_Y1, COLON_X0, COLON_X1, (BG_L, BG_R))),
              (SUFFIX_X0, CLOCK_Y0, lift(ref, CLOCK_Y0, CLOCK_Y1, SUFFIX_X0, BLOCK_X1, (BG_L, BG_R)))]
    for _, src_name, sx0, sx1, sy0, sy1, bgs, centre in GLYPHS:
        blocks.append((int(centre - (sx1 - sx0) / 2.0 + 0.5), sy0,
                       lift(images[src_name], sy0, sy1, sx0, sx1, bgs)))

    for a in images.values():
        fill_flat(a, CLOCK_Y0, CLOCK_Y1, BLOCK_X0, BLOCK_X1, BG_L)
        for tx0, ty0, delta in blocks:
            h, w = delta.shape[:2]
            bg = bg_field(a, ty0, ty0 + h, tx0, tx0 + w, BG_L, BG_R)
            a[ty0:ty0 + h, tx0:tx0 + w, :] = np.clip(bg + delta, 0, 255)


# ------------------------------------------------------- per-screen fixes --

NAV_XS = list(range(950, 1330))        # flat stretch of the Alternator nav bar


def clean_alternator(a):
    """Drop the blurred 'Delete core' ghost bleeding through the nav bar.

    The back button is deliberately left where the app puts it. Giving it more
    breathing room means moving it, and it cannot be moved without leaving a
    seam: only ~40px separate the sidebar card's edge from the button, and that
    gap is a shadow gully both of them cast into. Every candidate boundary for a
    shifted region except the top and right sits in non-flat pixels (the gully
    on the left, the History card below), and a radial blend wide enough to
    cover the old circle drags the card's bright edge into the dark gully. So
    the button stays put rather than carrying a rectangle of erased shadow.
    """
    fill_flat(a, 20, 88, 1360, 1665, xs=NAV_XS)


def clean_returns(a):
    """Clear the half-scrolled card header ghosting under the frosted nav bar,
    keeping the 'Returns' title that sits inside the same band. The band is
    rebuilt as a vertical blend so the bar's frosted-to-white fade survives."""
    title = ((1448, 86, 1596, 130), list(range(1250, 1420)))
    fill_vgrad(a, 58, 196, 828, 2190, keep=[title])   # rows 178-202 are clean


# ------------------------------------------------------------------ driver --

def load(d='.'):
    return {k: np.asarray(Image.open(f'{d}/{v}').convert('RGB')).astype(float)
            for k, v in SRC.items()}


def clean_all(d='.'):
    imgs = load(d)
    normalise_clock(imgs)
    clean_alternator(imgs['alternator'])
    clean_returns(imgs['returns'])
    return {k: Image.fromarray(np.clip(v, 0, 255).astype(np.uint8)) for k, v in imgs.items()}
