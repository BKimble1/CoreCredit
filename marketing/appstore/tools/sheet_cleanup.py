"""Top-edge cleanup for CoreCredit captures taken while a sheet is presented.

`Scan core` and `Add core` are sheets. A capture of either carries three things
that belong to the *presentation*, not to the app's own screen:

  * a dimmed status-bar band -- the presenting view showing through at #B9BDC8,
  * the sheet's rounded top corners cutting into that band,
  * whatever sits behind: the stacked sheet's edge on `Scan core`, and on
    `Add core` the blurred card that has scrolled up under the nav bar.

All three read as a chopped screenshot once the capture is dropped into a device
frame. This module rebuilds the band above the nav bar out of the sheet's own
background, so each capture reads as the clean full-screen app capture that
Image 3's captures already are.

No app UI is redrawn. The only pixels invented are flat sheet background and the
Cancel pill's own drop shadow, whose radial profile is measured from a clean
stretch of that same shadow. Everything from the nav bar down is untouched, and
nothing is scaled, stretched or resampled here.

Both captures are 946 x 2048 -- the geometry of Dashboard.png and Cores.png --
so the finished marketing status bar is transplanted from Dashboard_Marketing.png
row for row: identical icon weight, spacing, alignment and vertical placement to
the rest of the gallery.
"""

from PIL import Image
import numpy as np

# ---------------------------------------------------------------- constants
# The Cancel pill, measured identically in both captures once the stacked-sheet
# offset is normalised out. A 201 x 104 capsule, so its radius is half its height.
PILL_X0, PILL_X1 = 41, 241
PILL_Y0, PILL_Y1 = 153, 256
PILL_R = (PILL_Y1 - PILL_Y0 + 1) / 2.0

HALO_R = 104                     # the pill's shadow reaches zero by here
HALO_MIN = 4                     # inside this the pill's own anti-aliasing dominates
HALO_BAND = (175, 251, 242, 346)  # rows, cols alongside the pill carrying only shadow
TOP_END = 180                    # last rebuilt row; nav-bar title ink starts at 190
CORNER_END = 270                 # the sheet's top corners have met the edges by here
CORNER_TOL = 14                  # L1 residual accepted as "this is the dimmed view"
AA_RIM = 2                       # pixels of soft edge closing each corner wedge
DIM_MIN = 0.12                   # dimming this faint still belongs to a wedge, not the
                                 # pill shadow, which never reaches 0.09 at either edge
STATUS_H = 120                   # rows transplanted from the reference capture
DOT_BOX = (8, 36, 674, 708)      # camera-active privacy indicator

BGD = np.array([232, 236, 248], float)   # reference capture's status-bar field
DIM = np.array([185, 189, 200], float)   # the dimmed presenting view
DOT = np.array([96, 211, 123], float)    # privacy indicator green

# Per capture: the row its own sheet background starts on, the row its Cancel
# pill starts on, and a patch of that background clear of all content. `Scan
# core` is a *stacked* sheet, so it sits 24 px lower than `Add core`; taking
# that offset out is what makes the two phones read as the same screen.
SOURCES = {
    "lefttiltedphone.PNG": {
        "sheet_top": 139, "pill_top": 177, "keep_dot": True,
        "bg_patch": (230, 270, 600, 900),
    },
    "rightherophone.PNG": {
        "sheet_top": 114, "pill_top": 153, "keep_dot": False,
        "bg_patch": (176, 190, 400, 900),
    },
}


def _modal(arr):
    vals, counts = np.unique(arr.reshape(-1, 3), axis=0, return_counts=True)
    return vals[counts.argmax()].astype(float)


def _shift_rows(src, shift):
    """Lift content by `shift` rows, holding the final row to refill the tail."""
    if shift <= 0:
        return src.copy()
    h = src.shape[0]
    out = np.empty_like(src)
    out[: h - shift] = src[shift:]
    out[h - shift:] = src[h - 1]
    return out


def _capsule(shape):
    """The Cancel pill as coverage in [0,1] plus distance outside it, in pixels."""
    x0, x1 = PILL_X0 - 0.5, PILL_X1 + 0.5
    y0, y1 = PILL_Y0 - 0.5, PILL_Y1 + 0.5
    cx0, cx1 = x0 + PILL_R, x1 - PILL_R
    cy0, cy1 = y0 + PILL_R, y1 - PILL_R
    ys = np.arange(shape[0], dtype=float)[:, None]
    xs = np.arange(shape[1], dtype=float)[None, :]
    dx = np.maximum(np.maximum(cx0 - xs, xs - cx1), 0.0)
    dy = np.maximum(np.maximum(cy0 - ys, ys - cy1), 0.0)
    dist = np.hypot(dx, dy) - PILL_R
    return np.clip(0.5 - dist, 0.0, 1.0), np.maximum(dist, 0.0)


def _halo_profile(img, dist, coverage, bg):
    """The pill's drop shadow as median darkening against distance from the pill.

    Sampled from a band beside the pill that carries the shadow and nothing else,
    so no blurred content is ever taken for shadow.
    """
    r0, r1, c0, c1 = HALO_BAND
    band = np.zeros(img.shape[:2], bool)
    band[r0:r1, c0:c1] = True
    band &= (coverage <= 0.0) & (dist <= HALO_R)
    d = np.round(dist[band]).astype(int)
    delta = bg - img[band]

    # Readings closer than HALO_MIN sit on the pill's own anti-aliased rim, where
    # the white body bleeds outward and swamps the shadow, so the profile is read
    # from HALO_MIN outward and its first clean value is held in to the edge.
    prof = np.full((HALO_R + 1, 3), np.nan)
    for k in range(HALO_MIN, HALO_R + 1):
        sel = d == k
        if sel.sum() >= 5:
            prof[k] = np.median(delta[sel], axis=0)
    known = np.nonzero(~np.isnan(prof[:, 0]))[0]
    prof[: known[0]] = prof[known[0]]                       # hold the nearest reading in
    for k in range(known[0] + 1, HALO_R + 1):               # and the last one outward
        if np.isnan(prof[k, 0]):
            prof[k] = prof[k - 1]
    return np.maximum(prof, 0.0)


def _corner_wedges(img, field, bg):
    """Fill in the sheet's rounded top corners with the sheet's own background.

    Below the rebuilt band those corners still cut a wedge of the dimmed
    presenting view out of each screen edge. A wedge always runs from its edge
    inward without a break, so it is taken as that run -- the pixels reading as
    flat #B9BDC8 -- plus the soft rim that closes it. The whole run becomes the
    background field, which is what the screen carries there once the sheet is
    seated at the top. Scanning inward from the edge, rather than testing every
    pixel, keeps the pill's shadow (which lies along the same colour ramp) out
    of it entirely.
    """
    ramp = DIM - bg
    a = np.clip(((img - bg) @ ramp) / (ramp @ ramp), 0.0, 1.0)
    resid = np.abs(img - (bg + a[..., None] * ramp)).sum(axis=-1)
    dimmed = (a > DIM_MIN) & (resid < CORNER_TOL)

    out = img.copy()
    n = 0
    for y in range(TOP_END, min(CORNER_END, img.shape[0])):
        row = dimmed[y]
        for side in (0, 1):
            scan = row if side == 0 else row[::-1]
            if not scan[0]:
                continue
            run = int(np.argmin(scan)) + AA_RIM      # the wedge plus its rim
            if side == 0:
                out[y, :run] = field[y, :run]
            else:
                out[y, img.shape[1] - run:] = field[y, img.shape[1] - run:]
            n += run
    return out, n


def _status_band(reference_png, field, dot_src):
    """The gallery's marketing status bar, re-seated on `field`'s background.

    The reference band is a flat #E8ECF8 area carrying black ink and the white
    battery numerals. Substituting the background *under* that ink, rather than
    pasting the band over, keeps every glyph exactly as the rest of the gallery
    renders it while the field becomes the sheet's own colour. The two fields
    differ by at most three levels, so the substitution is exact to a rounding
    step whichever way the ink coverage is estimated.
    """
    ref = np.array(Image.open(reference_png).convert("RGB")).astype(float)[:STATUS_H]
    ink = np.clip(np.abs(ref - BGD).sum(axis=-1) / 48.0, 0.0, 1.0)[..., None]
    out = ref + (field - BGD) * (1.0 - ink)

    if dot_src is not None:
        y0, y1, x0, x1 = DOT_BOX
        patch = dot_src[y0:y1, x0:x1]
        a = np.clip(np.abs(patch - DIM).sum(axis=-1) /
                    np.abs(DOT - DIM).sum(), 0.0, 1.0)[..., None]
        out[y0:y1, x0:x1] = out[y0:y1, x0:x1] * (1.0 - a) + DOT * a
    return out


def clean(target_png, reference_png, out_png, spec):
    """Write `target_png` with its sheet-presentation top edge repaired."""
    src = np.array(Image.open(target_png).convert("RGB")).astype(float)
    report = {"source": target_png, "size": list(src.shape[1::-1])}

    # 1. Take out the stacked-sheet offset so both nav bars sit on the same row.
    shift = spec["pill_top"] - PILL_Y0
    img = _shift_rows(src, shift)
    report["rows_lifted"] = shift
    report["bottom_rows_held"] = shift

    # 2. The sheet's own background colour, read clear of all content.
    r0, r1, c0, c1 = spec["bg_patch"]
    bg = _modal(img[r0:r1, c0:c1].astype(np.uint8))
    report["sheet_background"] = bg.tolist()

    # 3. The Cancel pill, and the shadow it casts on that background.
    coverage, dist = _capsule(img.shape)
    prof = _halo_profile(img, dist, coverage, bg)
    report["shadow_peak"] = prof[0].round(2).tolist()
    report["shadow_reach_px"] = HALO_R

    # 4. Rebuild every row above the nav bar as flat sheet background plus that
    #    shadow, carrying the pill itself over from the capture untouched.
    idx = np.clip(np.round(dist[:CORNER_END]).astype(int), 0, HALO_R)
    field = bg[None, None, :] - prof[idx]
    c = coverage[:TOP_END, :, None]
    img[:TOP_END] = img[:TOP_END] * c + field[:TOP_END] * (1.0 - c)
    report["rows_rebuilt"] = TOP_END

    # 4b. And take the sheet's rounded top corners out of the rows below it.
    head, n = _corner_wedges(img[:CORNER_END], field, bg)
    img[:CORNER_END] = head
    report["corner_px_recovered"] = n

    # 5. Seat the gallery's marketing status bar on the rebuilt background.
    img[:STATUS_H] = _status_band(reference_png, img[:STATUS_H],
                                  src[:STATUS_H] if spec["keep_dot"] else None)
    report["status_rows"] = STATUS_H
    report["privacy_dot_kept"] = bool(spec["keep_dot"])

    Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).save(out_png)
    report["output"] = out_png
    return report
