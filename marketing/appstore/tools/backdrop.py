"""The gallery's blue backdrop, taken from the finished Image 3.

Image 3's background layer is the only place the gradient exists in full, and
the device covers its right-hand half. So the field is *read* out of that layer
rather than invented: a vertical ramp measured column by column, plus one broad
glow sitting behind the copy. Fitting the glow to the pixels Image 3 leaves
uncovered reproduces them to about one level RMS, which is inside the layer's
own dither, and gives the rest of the canvas the same field continued.

Nothing here is a taste decision -- every number comes out of a least-squares
fit against the committed layer, so Image 2's backdrop is Image 3's backdrop.
"""

from PIL import Image
import numpy as np
from scipy.optimize import least_squares

RAMP_COLS = 40          # left-hand strip that no copy, device or shadow touches
COPY_BOX = (600, 1340, 40, 640)   # Image 3's headline block, excluded from the fit
DEVICE_X = 556          # left of this the device and its shadow never reach
FIT_STEP = 8            # subsampling for the fit

# 4x4 ordered dither, matching the amplitude Image 3's own layer carries.
BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6],
                  [3, 11, 1, 9], [15, 7, 13, 5]], float)
DITHER = 1.6


def _glow(p, x, y):
    cx, sx, nx, cy, sy, ny = p
    return (np.exp(-0.5 * np.abs((x - cx) / sx) ** nx) *
            np.exp(-0.5 * np.abs((y - cy) / sy) ** ny))


def measure(background_png):
    """Fit the backdrop of `background_png`; returns the ramp, glow and report."""
    bg = np.array(Image.open(background_png).convert("RGB")).astype(float)
    h, w, _ = bg.shape
    ramp = np.median(bg[:, :RAMP_COLS], axis=1)          # V(y), per channel

    clean = np.zeros((h, w), bool)
    clean[:, :DEVICE_X] = True
    r0, r1, c0, c1 = COPY_BOX
    clean[r0:r1, c0:c1] = False
    ys, xs = np.nonzero(clean[::FIT_STEP, ::FIT_STEP])
    ys, xs = ys * FIT_STEP, xs * FIT_STEP
    resid_target = bg[ys, xs] - ramp[ys]
    anchor = np.full(xs.shape, float(RAMP_COLS // 2))

    def solve(p):
        d = (_glow(p, xs.astype(float), ys.astype(float)) -
             _glow(p, anchor, ys.astype(float)))[:, None]
        amp = np.linalg.lstsq(d, resid_target, rcond=None)[0]
        return d, amp

    sol = least_squares(lambda p: (lambda d, a: (d @ a - resid_target).ravel())(*solve(p)),
                        [645.0, 420.0, 2.0, 1500.0, 900.0, 3.0],
                        bounds=([300, 150, 1.2, 1000, 400, 1.2],
                                [1290, 1400, 8, 2200, 2000, 8]))
    d, amp = solve(sol.x)
    err = d @ amp - resid_target
    return {
        "size": (w, h),
        "ramp": ramp,
        "glow": sol.x,
        "amplitude": amp[0],
        "anchor_x": float(RAMP_COLS // 2),
        "fit_rms": err.std(axis=0).round(3).tolist(),
        "fit_max_abs": np.abs(err).max(axis=0).round(2).tolist(),
        "fit_samples": int(len(ys)),
    }


def field(fit, size=None):
    """The backdrop as a float RGB array of `size` (defaults to Image 3's)."""
    w, h = size or fit["size"]
    ys = np.arange(h, dtype=float)[:, None]
    xs = np.arange(w, dtype=float)[None, :]
    g = _glow(fit["glow"], xs, ys) - _glow(fit["glow"], np.full((1, 1), fit["anchor_x"]), ys)
    return fit["ramp"][:h, None, :] + g[..., None] * fit["amplitude"]


def quantise(rgb):
    """8-bit with the ordered dither that keeps a gradient this shallow from banding."""
    h, w, _ = rgb.shape
    t = (BAYER[np.arange(h) % 4][:, np.arange(w) % 4] / 15.0 - 0.5) * DITHER
    return np.clip(np.round(rgb + t[..., None]), 0, 255).astype(np.uint8)
