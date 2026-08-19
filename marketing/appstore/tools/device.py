"""The gallery's device frame, rebuilt from the one Image 3 already ships.

Image 3's phone is cropped by the canvas, so its overlay only carries a left
rail, a top and bottom edge and two corners. Image 2 needs two whole phones, one
of them tilted, so the frame is redrawn from measurements of that overlay rather
than cut out of it. Everything below is a reading of the committed layer:

  * the outline is a superellipse-cornered rect fitted to the overlay's own
    alpha -- R = 0.1463 W, exponent 2.321, matching it to about a pixel,
  * the bezel is 41.5 / 1000 of the screen width,
  * the rim and body colours are sampled straight off the template preview, and
    both are modulated by how side-on the edge is, which is what makes the left
    rail read bright against a nearly black top edge,
  * the button spans are the overlay's own protrusions.

Lengths are held as fractions of the screen width, so a frame at any size is the
same device. Frames are drawn supersampled and rotated as one piece, so a tilted
phone is a uniform rotation of the upright one -- never a stretch.
"""

from PIL import Image
import numpy as np
from scipy.ndimage import gaussian_filter

SCREEN_ASPECT = 1290.0 / 2796.0     # the 6.9" screen the captures come from

# --- geometry, as fractions of the screen width (Image 3: screen width 1000 px)
BEZEL = 41.5 / 1000
R_OUTER = 146.28 / 1000
SE_N = 2.321                        # superellipse exponent of the corners
BUTTON_OUT = 3.0 / 1000             # how far the buttons stand proud of the rail
# These two are quoted in Image 3 units -- thousandths of the screen width -- to
# match `inward` below, which is measured in the same units.
RIM_IN = 9.0                        # the bright rim runs from the edge to here
BODY_TAU = 46.6                     # how fast the rail's sheen falls off inward

# --- colours, sampled from CoreCredit_AppStore_03_Refined_Template.png
CORE = np.array([13, 17, 28], float)        # body, away from any side rail
RIM_EDGE = np.array([46, 54, 72], float)    # rim on a top or bottom edge
RIM_SIDE = np.array([145, 155, 178], float)  # rim on a left or right rail
BODY_RAIL = np.array([20, 22, 25], float)   # extra warmth a rail adds to the body
BUTTON = np.array([57, 66, 90], float)

# --- buttons, as fractions of screen height below the screen's top edge.
# The three on the left are Image 3's own; the right-hand one is the side button
# that its canvas crop cuts off.
BUTTONS_LEFT = [(0.2141, 0.2621), (0.2990, 0.3812), (0.3955, 0.4776)]
BUTTONS_RIGHT = [(0.3120, 0.4230)]

# --- the shadow the device casts, fitted to Image 3's background layer
SHADOW_SIGMA = 35.0 / 1000
SHADOW_DY = 16.0 / 1000
SHADOW_K = 0.28


def _rounded_box(shape, half, radius, n):
    """Superellipse-cornered box: signed distance, plus how side-on the edge is."""
    ys = np.arange(shape[0], dtype=float)[:, None] - shape[0] / 2.0 + 0.5
    xs = np.arange(shape[1], dtype=float)[None, :] - shape[1] / 2.0 + 0.5
    ax = np.abs(xs) - (half[0] - radius)
    ay = np.abs(ys) - (half[1] - radius)
    qx, qy = np.maximum(ax, 0.0), np.maximum(ay, 0.0)
    corner = (qx ** n + qy ** n) ** (1.0 / n)
    sdf = corner + np.minimum(np.maximum(ax, ay), 0.0) - radius

    # |nx| of the outward normal: 1 on a rail, 0 on a top/bottom edge.
    with np.errstate(divide="ignore", invalid="ignore"):
        gx = np.where(corner > 0, qx ** (n - 1), 0.0)
        gy = np.where(corner > 0, qy ** (n - 1), 0.0)
        mag = np.hypot(gx, gy)
        sideness = np.where(mag > 0, gx / np.where(mag > 0, mag, 1.0),
                            (ax >= ay).astype(float))
    return sdf, np.clip(sideness, 0.0, 1.0)


def _capsule_mask(shape, cx, y0, y1, half_w, radius):
    ys = np.arange(shape[0], dtype=float)[:, None]
    xs = np.arange(shape[1], dtype=float)[None, :]
    dy = np.maximum(np.maximum(y0 + radius - ys, ys - (y1 - radius)), 0.0)
    dx = np.maximum(np.abs(xs - cx) - (half_w - radius), 0.0)
    return np.clip(0.5 - (np.hypot(dx, dy) - radius), 0.0, 1.0)


def render(screen_w, screenshot, angle=0.0, ss=3):
    """A finished phone: `screenshot` seated in a frame `screen_w` px across.

    Returns (rgba, report). The screenshot is scaled once, uniformly, by the
    aperture's height; the whole assembly is then rotated as a single piece.
    """
    sw = int(round(screen_w)) * ss
    sh = int(round(sw / SCREEN_ASPECT))
    b = BEZEL * sw
    ow, oh = sw + 2 * b, sh + 2 * b
    pad = int(round(BUTTON_OUT * sw)) + 2 * ss
    shape = (int(round(oh)) + 2 * pad, int(round(ow)) + 2 * pad)

    sdf, sideness = _rounded_box(shape, (ow / 2.0, oh / 2.0), R_OUTER * sw, SE_N)
    outer = np.clip(0.5 - sdf, 0.0, 1.0)
    inward = np.maximum(-sdf, 0.0) * (1000.0 / sw)          # thousandths of screen width

    # Rim over the outermost band, body inside it, both lit by how side-on it is.
    s = sideness[..., None]
    rim = RIM_EDGE + (RIM_SIDE - RIM_EDGE) * s
    body = CORE + BODY_RAIL * s * np.exp(-np.maximum(inward - RIM_IN, 0.0)[..., None]
                                         / BODY_TAU)
    is_body = np.clip(inward - RIM_IN + 0.5, 0.0, 1.0)[..., None]
    frame = rim * (1.0 - is_body) + body * is_body

    # Buttons, standing proud of the rails.
    btn_r = 2.0 * ss
    for spans, side in ((BUTTONS_LEFT, -1), (BUTTONS_RIGHT, +1)):
        for a, z in spans:
            y0 = shape[0] / 2.0 - oh / 2.0 + b + a * sh
            y1 = shape[0] / 2.0 - oh / 2.0 + b + z * sh
            edge = shape[1] / 2.0 + side * ow / 2.0
            cx = edge + side * (BUTTON_OUT * sw) / 2.0
            m = _capsule_mask(shape, cx, y0, y1,
                              (BUTTON_OUT * sw) / 2.0 + 2 * ss, btn_r)[..., None]
            frame = frame * (1.0 - m) + BUTTON * m
            outer = np.maximum(outer, m[..., 0])

    # The screen aperture, and the capture seated in it.
    sdf_s, _ = _rounded_box(shape, (sw / 2.0, sh / 2.0), (R_OUTER * sw) - b, SE_N)
    screen = np.clip(0.5 - sdf_s, 0.0, 1.0)[..., None]

    shot = Image.open(screenshot).convert("RGB") if isinstance(screenshot, str) else screenshot
    scale = sh / shot.size[1]                                # uniform, driven by height
    scaled = shot.resize((int(round(shot.size[0] * scale)), int(round(sh))), Image.LANCZOS)
    px = np.array(scaled).astype(float)
    plate = np.zeros((shape[0], shape[1], 3), float)
    top = int(round(shape[0] / 2.0 - sh / 2.0))
    left = int(round(shape[1] / 2.0 - sw / 2.0))
    take_h = min(px.shape[0], shape[0] - top)
    take_w = min(px.shape[1], shape[1] - left)
    plate[top:top + take_h, left:left + take_w] = px[:take_h, :take_w]

    rgb = frame * (1.0 - screen) + plate * screen
    rgba = np.dstack([rgb, outer * 255.0])
    img = Image.fromarray(np.clip(rgba, 0, 255).astype(np.uint8), "RGBA")
    if angle:
        img = img.rotate(angle, resample=Image.BICUBIC, expand=True)
    img = img.resize((max(1, img.size[0] // ss), max(1, img.size[1] // ss)), Image.LANCZOS)

    return img, {
        "screen_px": [int(round(sw / ss)), int(round(sh / ss))],
        "outer_px": [int(round(ow / ss)), int(round(oh / ss))],
        "bezel_px": round(b / ss, 2),
        "corner_radius_px": round(R_OUTER * sw / ss, 2),
        "angle_deg": angle,
        "capture_scale": round(scale / ss, 6),
        "capture_cropped_right_px": int(round(max(0, px.shape[1] - sw) / ss)),
        "supersample": ss,
    }


def cast_shadow(canvas, rgba, xy, screen_w):
    """Darken `canvas` in place under `rgba`, the way Image 3's layer is darkened."""
    alpha = np.zeros(canvas.shape[:2], float)
    x, y = xy
    a = np.array(rgba)[:, :, 3].astype(float) / 255.0
    dy = int(round(SHADOW_DY * screen_w))
    y0, x0 = y + dy, x
    h = min(a.shape[0], canvas.shape[0] - max(y0, 0))
    w = min(a.shape[1], canvas.shape[1] - max(x0, 0))
    sy, sx = max(0, -y0), max(0, -x0)
    alpha[max(y0, 0):max(y0, 0) + h - sy, max(x0, 0):max(x0, 0) + w - sx] = a[sy:h, sx:w]
    alpha = gaussian_filter(alpha, SHADOW_SIGMA * screen_w)
    canvas *= (1.0 - SHADOW_K * alpha)[..., None]
    return float(alpha.max())


def paste(canvas, rgba, xy):
    """Alpha-composite `rgba` onto the float RGB `canvas` at `xy`."""
    x, y = xy
    a = np.array(rgba).astype(float)
    h, w = a.shape[:2]
    y0, x0 = max(y, 0), max(x, 0)
    y1, x1 = min(y + h, canvas.shape[0]), min(x + w, canvas.shape[1])
    if y1 <= y0 or x1 <= x0:
        return
    sub = a[y0 - y:y1 - y, x0 - x:x1 - x]
    al = (sub[:, :, 3] / 255.0)[..., None]
    canvas[y0:y1, x0:x1] = canvas[y0:y1, x0:x1] * (1.0 - al) + sub[:, :, :3] * al
