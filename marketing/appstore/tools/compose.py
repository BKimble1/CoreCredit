"""Drop a device screenshot into the CoreCredit App Store template.

Each template ships as two layers around a hole: a background carrying the blue
gradient, the marketing copy, the device body and its shadow, and a device
overlay carrying the frame, its highlights and the side buttons. The screen
aperture is exactly the region the overlay leaves transparent, so compositing
background -> screenshot -> overlay reproduces the template pixel for pixel with
the screenshot standing in for the placeholder. No template geometry is guessed
or adjusted here: the aperture is measured from the overlay's own alpha channel.

A template crops its device against the canvas -- Image 3 takes the phone's
right-hand side off the edge, Image 4 stands it centred and takes the bottom --
so the aperture is short of the device screen's aspect on one axis. The scale is
driven by the axis the canvas left whole, which fills the aperture on both and
leaves the crop where the template intended it.
"""

from PIL import Image
import numpy as np
from collections import deque

# The template's device is a 6.9" iPhone, whose screen is 1290 x 2796.
DEVICE_SCREEN_RATIO = 1290.0 / 2796.0


def aperture(overlay_png, inside=(1000, 1400)):
    """Measure the screen hole in the device overlay.

    Returns (left, top, visible_width, height, mask). The phone is deliberately
    cropped by the right canvas edge, so `visible_width` is only the part that
    lands on canvas.
    """
    alpha = np.array(Image.open(overlay_png).convert("RGBA"))[:, :, 3]
    free = alpha < 128
    h, w = free.shape
    mask = np.zeros_like(free)
    x0, y0 = inside
    mask[y0, x0] = True
    q = deque([(y0, x0)])
    while q:
        y, x = q.popleft()
        for ny, nx in ((y + 1, x), (y - 1, x), (y, x + 1), (y, x - 1)):
            if 0 <= ny < h and 0 <= nx < w and free[ny, nx] and not mask[ny, nx]:
                mask[ny, nx] = True
                q.append((ny, nx))
    ys, xs = np.nonzero(mask)
    return (int(xs.min()), int(ys.min()),
            int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1), mask)


def compose(background_png, overlay_png, screenshot_png, out_png):
    bg = Image.open(background_png).convert("RGBA")
    ov = Image.open(overlay_png).convert("RGBA")
    if bg.size != ov.size:
        raise ValueError(f"layer size mismatch: {bg.size} vs {ov.size}")
    left, top, visible_w, height, mask = aperture(overlay_png)

    shot = Image.open(screenshot_png).convert("RGB")
    sw, sh = shot.size

    # One factor on both axes, the larger of the two the aperture asks for, so
    # the screenshot covers the aperture whole and nothing is ever stretched.
    # The screenshot's aspect and the device screen's differ by a fraction of a
    # pixel over the full width, far inside the crop the template takes anyway.
    scale = max(height / sh, visible_w / sw)
    scaled_w, scaled_h = int(round(sw * scale)), int(round(sh * scale))
    design_w = height * DEVICE_SCREEN_RATIO       # aperture width if uncropped
    scaled = shot.resize((scaled_w, scaled_h), Image.LANCZOS)

    canvas = np.array(bg)
    px = np.array(scaled)
    take_w = min(scaled_w, canvas.shape[1] - left, visible_w)
    take_h = min(scaled_h, height)

    sub = canvas[top:top + take_h, left:left + take_w]
    sub_mask = mask[top:top + take_h, left:left + take_w]
    sub[..., :3] = np.where(sub_mask[..., None], px[:take_h, :take_w], sub[..., :3])

    out = Image.alpha_composite(Image.fromarray(canvas), ov).convert("RGB")
    out.save(out_png)

    return {
        "canvas": bg.size,
        "aperture": {"left": left, "top": top, "height": height,
                     "visible_width": visible_w,
                     "design_width": round(design_w, 2)},
        "screenshot": (sw, sh),
        "scale": round(scale, 6),
        "scaled": (scaled_w, scaled_h),
        "aspect_screenshot": round(sw / sh, 6),
        "aspect_device_screen": round(DEVICE_SCREEN_RATIO, 6),
        "aspect_width_delta_px": round(scaled_w - design_w, 2),
        "driven_by": "width" if visible_w / sw > height / sh else "height",
        "cropped_right_px": scaled_w - take_w,
        "cropped_right_pct": round(100.0 * (scaled_w - take_w) / scaled_w, 2),
        "cropped_bottom_px": scaled_h - take_h,
        "cropped_bottom_pct": round(100.0 * (scaled_h - take_h) / scaled_h, 2),
    }
