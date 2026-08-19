#!/usr/bin/env python3
"""Compose App Store screenshot Image 3 ("Cores") at 1290x2796.

Takes the real Cores.png device screenshot, applies the two permitted polish
fixes (a standard 9:41 status bar, and a cleanup of the partial row peeking
out from behind the floating tab bar), and places it inside the Image 3
template: blue gradient, headline, subtitle, right-biased iPhone.

Run:  python3 scripts/make_app_store_image3.py
"""

from __future__ import annotations

import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SOURCE = os.path.join(ROOT, "Cores.png")
OUTPUT = os.path.join(ROOT, "AppStore", "Image3-Cores-1290x2796.png")

FONT_DIR = os.environ.get("INTER_TTF_DIR", "/tmp/inter/extras/ttf")


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)


# ---------------------------------------------------------------- canvas ----

CANVAS_W, CANVAS_H = 1290, 2796

# Phone geometry. The frame is right-biased and bleeds past the right edge of
# the canvas; the screen aspect matches the source screenshot exactly so the
# UI is never stretched.
FRAME_BORDER = 24
FRAME_RIGHT_BLEED = 52          # px of frame past the right canvas edge
FRAME_TOP = 700
FRAME_H = 2140                  # bleeds past the bottom edge as well
OUTER_RADIUS = 132

HEADLINE = ["Track every core", "at a glance."]
SUBTITLE = ["Stay on top of what’s ready, overdue,", "and still at risk."]

TEXT_LEFT = 92
HEADLINE_TOP = 196
HEADLINE_SIZE = 112
HEADLINE_LEADING = 1.055
SUBTITLE_SIZE = 48
SUBTITLE_LEADING = 1.30
SUBTITLE_GAP = 54


# ------------------------------------------------------- polish: statusbar --

STATUS_BG = (232, 236, 248)
STATUS_CLEAR = (0, 28, 946, 96)   # flat header band around the status glyphs
STATUS_MID_Y = 62                 # vertical centre of the status glyphs
TIME_CENTRE_X = 155               # matches the centre of the original clock
RIGHT_EDGE_X = 866                # matches the right edge of the original battery


def draw_status_bar(screen: Image.Image, scale: float) -> None:
    """Draw a clean App Store status bar (9:41, full signal, Wi-Fi, battery).

    Drawn straight onto the already-scaled screen so the glyphs stay crisp,
    at 4x supersampling. Geometry is expressed in source-screenshot pixels and
    multiplied by `scale`.
    """
    ss = 4
    w = int(round(946 * scale))
    h = int(round(96 * scale))
    layer = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    black = (0, 0, 0, 255)

    def sx(v: float) -> float:
        return v * scale * ss

    mid = sx(STATUS_MID_Y)

    # 9:41 -------------------------------------------------------------------
    # The original clock glyphs run y=46..78 in source pixels (32px tall);
    # Inter digits are 0.727em, so match that cap height.
    time_font = font("Inter-SemiBold.ttf", int(round(32 / 0.727 * scale * ss)))
    d.text((sx(TIME_CENTRE_X), mid), "9:41", font=time_font, fill=black, anchor="mm")

    # Right-hand glyph cluster, right-aligned to the original battery edge ----
    bat_w, bat_h, nub_w, gap = 52.0, 26.0, 4.0, 10.0
    wifi_w, sig_w = 35.0, 42.0

    right = RIGHT_EDGE_X
    bat_x1 = right - nub_w
    bat_x0 = bat_x1 - bat_w
    wifi_x1 = bat_x0 - gap
    wifi_x0 = wifi_x1 - wifi_w
    sig_x1 = wifi_x0 - gap
    sig_x0 = sig_x1 - sig_w

    # Cellular: four bars, all full.
    bar_w, bar_gap = 7.5, 4.0
    bottom = STATUS_MID_Y + 13
    for i in range(4):
        bh = 9.5 + i * 4.5
        x0 = sig_x0 + i * (bar_w + bar_gap)
        d.rounded_rectangle(
            [sx(x0), sx(bottom - bh), sx(x0 + bar_w), sx(bottom)],
            radius=sx(1.9), fill=black,
        )

    # Wi-Fi: three arcs plus the dot.
    wifi_cx = (wifi_x0 + wifi_x1) / 2.0
    wifi_base = STATUS_MID_Y + 12.5
    for radius, width in ((16.6, 4.6), (10.6, 4.6), (4.4, 4.4)):
        d.arc(
            [sx(wifi_cx - radius), sx(wifi_base - radius),
             sx(wifi_cx + radius), sx(wifi_base + radius)],
            start=215, end=325, fill=black, width=int(round(sx(width))),
        )
    d.ellipse(
        [sx(wifi_cx - 2.5), sx(wifi_base - 2.5), sx(wifi_cx + 2.5), sx(wifi_base + 2.5)],
        fill=black,
    )

    # Battery: outline, full charge, terminal nub.
    top, bot = STATUS_MID_Y - bat_h / 2, STATUS_MID_Y + bat_h / 2
    stroke = 2.3
    d.rounded_rectangle(
        [sx(bat_x0), sx(top), sx(bat_x1), sx(bot)],
        radius=sx(7.5), outline=(0, 0, 0, 92), width=int(round(sx(stroke))),
    )
    inset = stroke + 2.6
    d.rounded_rectangle(
        [sx(bat_x0 + inset), sx(top + inset), sx(bat_x1 - inset), sx(bot - inset)],
        radius=sx(4.4), fill=black,
    )
    d.rounded_rectangle(
        [sx(bat_x1 + 1.6), sx(STATUS_MID_Y - 4.4), sx(bat_x1 + 4.2), sx(STATUS_MID_Y + 4.4)],
        radius=sx(1.3), fill=(0, 0, 0, 92),
    )

    layer = layer.resize((w, h), Image.LANCZOS)
    screen.paste(layer, (0, 0), layer)


# ----------------------------------------------------- polish: bottom edge --

SEPARATOR_Y = 1845      # the hairline that closes the Reman Transmission row
PILL = (51, 1847, 896, 1996)   # floating tab bar bounding box, source pixels
PILL_RADIUS = 75
CAPSULE = (258, 1859, 489, 1985)   # the selected "Cores" tab capsule
CAPSULE_RADIUS = 63


def clean_bottom_edge(src: Image.Image) -> Image.Image:
    """Erase the partial row peeking out from behind the floating tab bar.

    Everything below the last separator that falls outside the tab bar is
    repainted with the page background sampled from the clean left gutter,
    then the tab bar's soft drop shadow is rebuilt so it still sits on the
    page rather than being cut out of it.
    """
    src = src.convert("RGB")
    w, h = src.size
    px = src.load()

    # Per-row background colour, taken from the gutter left of the tab bar,
    # smoothed so scanline noise does not band.
    raw = []
    for y in range(SEPARATOR_Y, h):
        band = [px[x, y] for x in range(4, 34)]
        band.sort(key=sum)
        raw.append(band[len(band) // 2])
    smooth = []
    for i in range(len(raw)):
        lo, hi = max(0, i - 8), min(len(raw), i + 9)
        chunk = raw[lo:hi]
        smooth.append(tuple(sum(c[k] for c in chunk) // len(chunk) for k in range(3)))

    clean = src.copy()
    cd = ImageDraw.Draw(clean)
    for i, y in enumerate(range(SEPARATOR_Y, h)):
        cd.line([(0, y), (w, y)], fill=smooth[i])

    # Rebuild the tab bar's drop shadow on the repainted background.
    ss = 4
    shadow = Image.new("L", (w * ss, (h - SEPARATOR_Y) * ss), 0)
    sd = ImageDraw.Draw(shadow)
    x0, y0, x1, y1 = PILL
    sd.rounded_rectangle(
        [x0 * ss, (y0 - SEPARATOR_Y + 5) * ss, x1 * ss, (y1 - SEPARATOR_Y + 7) * ss],
        radius=PILL_RADIUS * ss, fill=54,
    )
    shadow = shadow.resize((w, h - SEPARATOR_Y), Image.LANCZOS)
    shadow = shadow.filter(ImageFilter.GaussianBlur(11))
    dark = Image.new("RGB", shadow.size, (108, 116, 140))
    region = clean.crop((0, SEPARATOR_Y, w, h))
    region = Image.composite(dark, region, shadow.point(lambda v: v))
    region = Image.blend(clean.crop((0, SEPARATOR_Y, w, h)), region, 1.0)
    clean.paste(region, (0, SEPARATOR_Y))

    # Put the tab bar itself back, unaltered.
    mask = Image.new("L", (w * ss, h * ss), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle([x0 * ss, y0 * ss, x1 * ss, y1 * ss],
                         radius=PILL_RADIUS * ss, fill=255)
    mask = mask.resize((w, h), Image.LANCZOS)
    clean.paste(src, (0, 0), mask)

    return _defrost_tab_bar(clean)


def _defrost_tab_bar(img: Image.Image) -> Image.Image:
    """Lift the same partial row where it shows through the frosted tab bar.

    Only the pale ghosting is touched: the tab bar's own icons, labels and
    selected capsule are masked out and copied through untouched.
    """
    w, h = img.size
    x0, y0, x1, y1 = PILL
    box = (x0, y0, x1 + 1, y1 + 1)
    region = img.crop(box)

    # Erase the thin pale strokes by taking the local maximum, then soften.
    lifted = region.filter(ImageFilter.MaxFilter(9)).filter(
        ImageFilter.GaussianBlur(2.2))

    # Protect anything the tab bar actually draws.
    gray = region.convert("L")
    protect = gray.point(lambda v: 255 if v < 212 else 0)
    protect = protect.filter(ImageFilter.MaxFilter(7))
    pd = ImageDraw.Draw(protect)
    cx0, cy0, cx1, cy1 = CAPSULE
    pd.rounded_rectangle(
        [cx0 - x0 - 8, cy0 - y0 - 8, cx1 - x0 + 8, cy1 - y0 + 8],
        radius=CAPSULE_RADIUS + 8, fill=255,
    )
    protect = protect.filter(ImageFilter.GaussianBlur(1.4))

    merged = Image.composite(region, lifted, protect)

    # Confine the edit to the tab bar's rounded shape, inset off its own edge.
    ss = 4
    shape = Image.new("L", ((x1 - x0 + 1) * ss, (y1 - y0 + 1) * ss), 0)
    ImageDraw.Draw(shape).rounded_rectangle(
        [3 * ss, 3 * ss, (x1 - x0 - 3) * ss, (y1 - y0 - 3) * ss],
        radius=(PILL_RADIUS - 3) * ss, fill=255,
    )
    shape = shape.resize((x1 - x0 + 1, y1 - y0 + 1), Image.LANCZOS)

    out = img.copy()
    out.paste(Image.composite(merged, region, shape), box)
    return out


# ---------------------------------------------------------------- template --

def background() -> Image.Image:
    """Blue brand gradient, deep at the top, brand blue through the middle."""
    stops = [(0.00, (10, 55, 196)), (0.42, (0, 85, 252)),
             (0.74, (7, 70, 226)), (1.00, (6, 44, 158))]
    bg = Image.new("RGB", (1, CANVAS_H))
    b = bg.load()
    for y in range(CANVAS_H):
        t = y / (CANVAS_H - 1)
        for i in range(len(stops) - 1):
            t0, c0 = stops[i]
            t1, c1 = stops[i + 1]
            if t0 <= t <= t1:
                f = (t - t0) / (t1 - t0)
                b[0, y] = tuple(int(round(c0[k] + (c1[k] - c0[k]) * f)) for k in range(3))
                break
    bg = bg.resize((CANVAS_W, CANVAS_H))

    # Soft highlight behind the headline so the white type has some lift.
    glow = Image.new("L", (CANVAS_W, CANVAS_H), 0)
    ImageDraw.Draw(glow).ellipse([-520, -900, 1180, 900], fill=64)
    glow = glow.filter(ImageFilter.GaussianBlur(230))
    bg = Image.composite(Image.new("RGB", bg.size, (56, 122, 255)), bg, glow)
    return bg


def draw_copy(canvas: Image.Image) -> None:
    d = ImageDraw.Draw(canvas)
    head = font("InterDisplay-Bold.ttf", HEADLINE_SIZE)
    sub = font("Inter-Regular.ttf", SUBTITLE_SIZE)

    y = HEADLINE_TOP
    line_h = int(round(HEADLINE_SIZE * HEADLINE_LEADING))
    for line in HEADLINE:
        d.text((TEXT_LEFT, y), line, font=head, fill=(255, 255, 255))
        y += line_h

    y += SUBTITLE_GAP
    sub_h = int(round(SUBTITLE_SIZE * SUBTITLE_LEADING))
    for line in SUBTITLE:
        d.text((TEXT_LEFT, y), line, font=sub, fill=(219, 231, 255))
        y += sub_h


def main() -> None:
    src = Image.open(SOURCE)
    src = clean_bottom_edge(src)

    # Screen rect, sized from the source aspect ratio so nothing is stretched.
    screen_h = FRAME_H - 2 * FRAME_BORDER
    screen_w = int(round(screen_h * src.width / src.height))
    frame_w = screen_w + 2 * FRAME_BORDER
    frame_x0 = CANVAS_W + FRAME_RIGHT_BLEED - frame_w
    frame_y0 = FRAME_TOP
    screen_x0 = frame_x0 + FRAME_BORDER
    screen_y0 = frame_y0 + FRAME_BORDER

    scale = screen_w / src.width
    screen = src.resize((screen_w, screen_h), Image.LANCZOS).convert("RGB")

    # Blank the original status band, then draw the App Store one.
    ImageDraw.Draw(screen).rectangle(
        [0, int(STATUS_CLEAR[1] * scale), screen_w, int(round(STATUS_CLEAR[3] * scale))],
        fill=STATUS_BG,
    )
    draw_status_bar(screen, scale)

    canvas = background()
    draw_copy(canvas)

    ss = 2
    fx0, fy0 = frame_x0 * ss, frame_y0 * ss
    fx1, fy1 = (frame_x0 + frame_w) * ss, (frame_y0 + FRAME_H) * ss

    # Drop shadow under the device.
    sh = Image.new("L", (CANVAS_W * ss, CANVAS_H * ss), 0)
    ImageDraw.Draw(sh).rounded_rectangle(
        [fx0 + 8 * ss, fy0 + 26 * ss, fx1 + 8 * ss, fy1 + 26 * ss],
        radius=OUTER_RADIUS * ss, fill=150,
    )
    sh = sh.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)
    sh = sh.filter(ImageFilter.GaussianBlur(46))
    canvas = Image.composite(Image.new("RGB", canvas.size, (2, 18, 74)), canvas, sh)

    # Screen mask, then the screenshot itself.
    smask = Image.new("L", (CANVAS_W * ss, CANVAS_H * ss), 0)
    ImageDraw.Draw(smask).rounded_rectangle(
        [screen_x0 * ss, screen_y0 * ss,
         (screen_x0 + screen_w) * ss, (screen_y0 + screen_h) * ss],
        radius=(OUTER_RADIUS - FRAME_BORDER) * ss, fill=255,
    )
    smask = smask.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)
    shot = Image.new("RGB", (CANVAS_W, CANVAS_H), (255, 255, 255))
    shot.paste(screen, (screen_x0, screen_y0))
    canvas = Image.composite(shot, canvas, smask)

    # Device frame: dark body with a hole cut for the screen, plus a bright rim.
    frame = Image.new("RGBA", (CANVAS_W * ss, CANVAS_H * ss), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.rounded_rectangle([fx0, fy0, fx1, fy1], radius=OUTER_RADIUS * ss,
                         fill=(22, 23, 27, 255))
    fd.rounded_rectangle([fx0, fy0, fx1, fy1], radius=OUTER_RADIUS * ss,
                         outline=(126, 132, 146, 255), width=int(2.6 * ss))
    fd.rounded_rectangle(
        [screen_x0 * ss, screen_y0 * ss,
         (screen_x0 + screen_w) * ss, (screen_y0 + screen_h) * ss],
        radius=(OUTER_RADIUS - FRAME_BORDER) * ss, fill=(0, 0, 0, 0),
    )
    frame = frame.resize((CANVAS_W, CANVAS_H), Image.LANCZOS)
    canvas = Image.alpha_composite(canvas.convert("RGBA"), frame).convert("RGB")

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    canvas.save(OUTPUT, "PNG")
    print(f"{OUTPUT}  {canvas.size[0]}x{canvas.size[1]}")
    print(f"screen rect x={screen_x0} y={screen_y0} w={screen_w} h={screen_h} "
          f"scale={scale:.4f}")


if __name__ == "__main__":
    main()
