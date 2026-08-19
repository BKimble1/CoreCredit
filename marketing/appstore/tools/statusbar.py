"""Finalized App Store status-bar treatment for CoreCredit screenshots.

Every geometry constant below was measured from Dashboard.png (the reference
capture): glyph positions, icon sizes, icon spacing, vertical position and the
left/right margins are reused verbatim so that every marketing screenshot reads
as the same device. Only the values that make it a *marketing* capture change:
the clock becomes 9:41, the cellular bars read full, and the battery reads 100%.

The Wi-Fi glyph, the signal-bar shapes and the battery shell are copied pixel
for pixel out of Dashboard.png rather than redrawn.
"""

from PIL import Image, ImageDraw, ImageFont
import numpy as np

# ---------------------------------------------------------------- constants
BG = np.array([232, 236, 248], dtype=float)   # status-bar background, both captures
INK = np.array([0, 0, 0], dtype=float)        # black Light Mode ink
BAR_GRAY = np.array([185, 189, 200], dtype=float)   # unfilled cellular bar
BATT_GRAY = np.array([163, 165, 177], dtype=float)  # unfilled battery track

# measured from Dashboard.png
ICON_BAND = (680, 40, 900, 92)      # x0, y0, x1, y1 of the right-hand icon cluster
TIME_BAND = (90, 40, 240, 92)       # x0, y0, x1, y1 of the clock
TIME_CENTER_X = 155                 # ink centre of the clock in both captures
TIME_INK_TOP = 48                   # top row of the clock's digit ink
BARS_BOX = (690, 45, 746, 79)       # cellular bars, incl. the two grey ones
BATT_BODY = (814, 43, 876, 81)      # battery shell (excludes the nub at x>=877)
BATT_CENTER_X = 846                 # ink centre of the battery numerals
BATT_NUM_TOP = 53                   # top row of the battery numeral ink
BATT_DIGIT_ADVANCE = 17             # tabular advance used for the 3-digit "100"

FONT_DIR = None                     # set by the caller


def _font(weight, size):
    return ImageFont.truetype(f"{FONT_DIR}/Inter-{weight}.ttf", size)


def _coverage(px, fill):
    """Per-pixel coverage of `fill` over BG, from an anti-aliased composite."""
    num = (BG - px).sum(axis=-1)
    den = (BG - fill).sum()
    return np.clip(num / den, 0.0, 1.0)


def _fill_holes(mask):
    """Binary hole fill: anything not reachable from the border is interior."""
    h, w = mask.shape
    outside = np.zeros_like(mask)
    stack = []
    for x in range(w):
        for y in (0, h - 1):
            if not mask[y, x] and not outside[y, x]:
                outside[y, x] = True; stack.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if not mask[y, x] and not outside[y, x]:
                outside[y, x] = True; stack.append((y, x))
    while stack:
        y, x = stack.pop()
        for ny, nx in ((y+1, x), (y-1, x), (y, x+1), (y, x-1)):
            if 0 <= ny < h and 0 <= nx < w and not mask[ny, nx] and not outside[ny, nx]:
                outside[ny, nx] = True; stack.append((ny, nx))
    return ~outside


def _blit_text(arr, text, font, color, center_x, ink_top):
    """Draw `text` so its ink bbox is centred on center_x and starts at ink_top."""
    pad = 200
    layer = Image.new("L", (pad * 3, pad), 0)
    ImageDraw.Draw(layer).text((pad // 2, pad // 4), text, font=font, fill=255)
    a = np.array(layer).astype(float) / 255.0
    ys, xs = np.nonzero(a > 0.35)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    a = a[y0:y1 + 1, x0:x1 + 1]
    h, w = a.shape
    dx = int(round(center_x - (w - 1) / 2.0))
    _composite(arr, a, dx, ink_top, color)
    return dx, ink_top, w, h


def _composite(arr, alpha, x, y, color):
    h, w = alpha.shape
    region = arr[y:y + h, x:x + w].astype(float)
    a = alpha[..., None]
    arr[y:y + h, x:x + w] = np.clip(region * (1 - a) + np.array(color, float) * a, 0, 255)


def _digit_cells(text, font, advance):
    """Render `text` with tabular spacing; returns (alpha, width, height)."""
    cells = []
    for ch in text:
        layer = Image.new("L", (120, 120), 0)
        ImageDraw.Draw(layer).text((40, 30), ch, font=font, fill=255)
        a = np.array(layer).astype(float) / 255.0
        ys, xs = np.nonzero(a > 0.35)
        cells.append((a, ys.min(), ys.max(), xs.min(), xs.max()))
    top = min(c[1] for c in cells)
    bot = max(c[2] for c in cells)
    h = bot - top + 1
    out = np.zeros((h, advance * len(text)), dtype=float)
    for i, (a, _, _, x0, x1) in enumerate(cells):
        gw = x1 - x0 + 1
        cx = i * advance + (advance - gw) // 2
        out[:, cx:cx + gw] = np.maximum(out[:, cx:cx + gw], a[top:bot + 1, x0:x1 + 1])
    return out


# ---------------------------------------------------------------- treatment
def finalize(target_png, reference_png, out_png, font_dir):
    """Write `target_png` with the finalized marketing status bar applied."""
    global FONT_DIR
    FONT_DIR = font_dir

    tgt = np.array(Image.open(target_png).convert("RGB")).astype(float)
    ref = np.array(Image.open(reference_png).convert("RGB")).astype(float)
    report = {}

    # 1. Transplant the reference capture's right-hand icon cluster verbatim.
    #    Both captures share an identical flat #E8ECF8 status-bar background,
    #    so this is a seamless pixel copy: same Wi-Fi glyph, same bar shapes,
    #    same battery shell, same spacing, same margins.
    x0, y0, x1, y1 = ICON_BAND
    tgt[y0:y1, x0:x1] = ref[y0:y1, x0:x1]
    report["icon_band_copied"] = ICON_BAND

    # 2. Cellular: fill the two grey bars, reusing their exact anti-aliased shape.
    bx0, by0, bx1, by1 = BARS_BOX
    box = tgt[by0:by1, bx0:bx1]
    grey = np.abs(box - BAR_GRAY).sum(axis=-1) < 200
    near_bg = np.abs(box - BG).sum(axis=-1) < 6
    touch = grey | (~near_bg & (np.abs(box - INK).sum(axis=-1) > 60))
    cov = _coverage(box, BAR_GRAY)
    cov = np.where(touch, cov, 0.0)
    box[:] = np.where(touch[..., None],
                      BG * (1 - cov[..., None]) + INK * cov[..., None],
                      box)
    report["bars_filled"] = int(touch.sum())

    # 3. Battery: fill the shell solid, then set the numerals to 100.
    ex0, ey0, ex1, ey1 = BATT_BODY
    shell = tgt[ey0:ey1, ex0:ex1]
    notbg = np.abs(shell - BG).sum(axis=-1) > 25
    body = _fill_holes(notbg)                      # numerals are interior holes
    # The shell edge is anti-aliased against two different fills (the black
    # charged part and the grey track), so recover each rim pixel's true
    # coverage from whichever BG->fill ramp its colour actually sits on.
    cov = np.where(_nearer(shell, INK, BATT_GRAY),
                   _coverage(shell, INK), _coverage(shell, BATT_GRAY))
    cov = np.where(_erode(body), 1.0, cov)         # solid interior
    cov = np.where(body, cov, 0.0)                 # never paint outside the shell
    shell[:] = np.where(body[..., None],
                        BG * (1 - cov[..., None]) + INK * cov[..., None],
                        shell)
    report["battery_body_px"] = int(body.sum())

    numerals = _digit_cells("100", _font("SemiBold", 27), BATT_DIGIT_ADVANCE)
    nw = numerals.shape[1]
    _composite(tgt, numerals, int(round(BATT_CENTER_X - (nw - 1) / 2.0)),
               BATT_NUM_TOP, (255, 255, 255))
    report["battery_numerals"] = ("100", nw, numerals.shape[0])

    # 4. Clock: 9:41, matched to the reference's ink height, centre and baseline.
    tx0, ty0, tx1, ty1 = TIME_BAND
    tgt[ty0:ty1, tx0:tx1] = BG
    report["time"] = _blit_text(tgt, "9:41", _font("SemiBold", 42), INK,
                                TIME_CENTER_X, TIME_INK_TOP)

    Image.fromarray(tgt.astype(np.uint8)).save(out_png)
    return report


def _nearer(px, fill_a, fill_b):
    """True where px sits closer to the BG->fill_a ramp than the BG->fill_b one."""
    def dist(fill):
        d = fill - BG
        t = np.clip(((px - BG) * d).sum(-1) / (d * d).sum(), 0.0, 1.0)
        return np.linalg.norm(px - (BG + t[..., None] * d), axis=-1)
    return dist(fill_a) <= dist(fill_b)


def _erode(mask):
    m = mask.copy()
    m[1:, :] &= mask[:-1, :]
    m[:-1, :] &= mask[1:, :]
    m[:, 1:] &= mask[:, :-1]
    m[:, :-1] &= mask[:, 1:]
    return m
