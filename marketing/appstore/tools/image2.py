"""CoreCredit App Store Image 2 -- "Capture a core in seconds."

A double-phone composition on the gallery's shared 1290 x 2796 canvas: the copy
block at the top, a tilted rear phone carrying the scan, and a larger upright
hero phone in front carrying the filled-in Add core screen ready to save. The
story reads left to right -- scan, review, save.

Backdrop, type and device frame all come from `backdrop`, `copydeck` and
`device`, each of which is a measurement of the finished Image 3 rather than a
fresh design decision, so the two images sit together as one gallery. The only
thing settled here is where the two phones go.
"""

from PIL import Image
import numpy as np

import backdrop
import copydeck
import device

CANVAS = (1290, 2796)
PLACEHOLDER = np.array([241, 245, 250], np.uint8)   # Image 3's own placeholder screen

HEADLINE = ["Capture a core", "in seconds."]
SUBTITLE = ["Scan it. Review the details. Save."]
FIRST_BASELINE = 420

# Rear phone: tilted, up and to the left, carrying the scan. Front phone: bigger,
# upright, down and to the right, and the most readable thing on the canvas.
REAR = {"screen_w": 620, "angle": -5.5, "centre": (433, 1486)}
FRONT = {"screen_w": 760, "angle": 0.0, "outer_topleft": (442, 940)}


def _placeholder(size):
    im = Image.new("RGB", size, tuple(int(c) for c in PLACEHOLDER))
    return im


def _phone(spec, screenshot, ss):
    rgba, rep = device.render(spec["screen_w"], screenshot, spec["angle"], ss)
    w, h = rgba.size
    if "centre" in spec:
        x = int(round(spec["centre"][0] - w / 2.0))
        y = int(round(spec["centre"][1] - h / 2.0))
    else:
        x, y = spec["outer_topleft"]
    rep["placed_at"] = [x, y]
    rep["sprite_px"] = [w, h]
    return rgba, (x, y), rep


def compose(background_png, rear_shot, front_shot,
            out_background, out_template, out_final, ss=3):
    """Build Image 2, and the backdrop and placeholder template it is built on."""
    fit = backdrop.measure(background_png)
    report = {"canvas": list(CANVAS), "backdrop_fit": {
        "glow": [round(v, 3) for v in fit["glow"]],
        "amplitude": [round(v, 3) for v in fit["amplitude"]],
        "rms_vs_image3": fit["fit_rms"], "max_abs_vs_image3": fit["fit_max_abs"],
        "samples": fit["fit_samples"]}}

    # The gradient is dithered once, here, and everything else is composited on
    # top of the dithered result -- so the captures are never re-dithered.
    base = backdrop.field(fit, CANVAS)
    report["copy"] = copydeck.draw(base, HEADLINE, SUBTITLE, FIRST_BASELINE)
    base8 = backdrop.quantise(base)
    Image.fromarray(base8).save(out_background)
    base = base8.astype(float)

    # Two passes over the same layout: the placeholder template, then the real one.
    for label, shots, out in (("template", (None, None), out_template),
                              ("final", (rear_shot, front_shot), out_final)):
        canvas = base.copy()
        stage = {}
        sprites = []
        for name, spec, shot in (("rear", REAR, shots[0]), ("front", FRONT, shots[1])):
            sw = spec["screen_w"]
            sh = int(round(sw / device.SCREEN_ASPECT))
            src = shot if shot else _placeholder((int(sw), sh))
            rgba, xy, rep = _phone(spec, src, ss)
            sprites.append((name, spec, rgba, xy))
            stage[name] = rep
        # Back to front, so the hero phone casts its shadow onto the rear one
        # rather than onto backdrop the rear phone then covers up.
        for name, spec, rgba, xy in sprites:
            stage[name]["shadow_peak"] = round(
                device.cast_shadow(canvas, rgba, xy, spec["screen_w"]), 4)
            device.paste(canvas, rgba, xy)
        out_img = Image.fromarray(np.clip(np.round(canvas), 0, 255).astype(np.uint8))
        if out_img.size != CANVAS:
            raise SystemExit(f"canvas is {out_img.size}, expected {CANVAS}")
        out_img.save(out)
        report[label] = stage

    report["outputs"] = [out_background, out_template, out_final]
    return report
