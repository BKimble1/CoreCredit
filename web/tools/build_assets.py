#!/usr/bin/env python3
"""Derive the website's images from the app assets already committed at the repository root.

    python3 web/tools/build_assets.py

Every picture on corecredit.idlery.com is a real capture of the shipping app or the shipping
app icon. Nothing here draws a fake screen, and nothing on the site loads an image from somebody
else's server, so this script is the only place a marketing image comes from.

What it reads (all committed, none modified):

  Dashboard_Marketing.png, Cores_Marketing.png, image4.PNG, image5.png, Image 6.png,
  lefttiltedphone.PNG, rightherophone.PNG   — iPhone captures, 946x2048 (image5 is 1170x2532)
  IMG_0313.PNG         — iPad landscape capture, 2360x1640
  CoreCredit/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png — the 1024 app icon

What it writes into web/src/assets/:

  shot-*.webp     the captures, status bar cropped away, resized for the web
  icon-*.png      the app icon, rounded the way iOS rounds it
  og.png          the 1200x630 social preview

The status bar is cropped rather than rewritten. A gallery that mixes 9:41 with 5:22 reads as
careless, and inventing a status bar for a capture that never had one is the kind of small
untruth this product is not in the business of telling. The third column below is the first row of real
content in each capture, measured once by looking for where the status bar ink stops.

The fourth column is where the capture ends. A live capture catches the next list row
half-scrolled *under* the floating tab bar; the two Dashboard/Cores sources are the
`_Marketing` variants, which `marketing/appstore/tools/bottom_cleanup.py` has already repaired,
and the rest simply stop a few pixels below the tab bar so the leftover sliver never shows.
"""

import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "web", "src", "assets")
FONT_DIR = os.path.join(ROOT, "marketing", "appstore", "tools", "fonts")

ICON = os.path.join(ROOT, "CoreCredit", "Resources", "Assets.xcassets",
                    "AppIcon.appiconset", "AppIcon.png")

ACCENT = (0, 83, 253)
INK = (11, 18, 32)

# source file, output name, first row of content, last row kept, target width
SHOTS = [
    ("Dashboard_Marketing.png", "shot-dashboard", 80,  2012, 660),
    ("Cores_Marketing.png",     "shot-cores",     80,  2012, 660),
    ("image5.png",              "shot-detail",    98,  2488, 660),
    ("lefttiltedphone.PNG",     "shot-scan",      80,  2012, 660),
    ("rightherophone.PNG",      "shot-add",       80,  2048, 660),
    ("Image 6.png",             "shot-timeline",  110, 2012, 660),
    # image4's capture caught a half-scrolled button ghosting over the "Returns" title, so this
    # one starts below the title bar: the vendor groups are the part worth showing anyway.
    ("image4.PNG",              "shot-returns",   215, 2007, 660),
]

IPAD = ("IMG_0313.PNG", "shot-ipad", 1200)


def rounded_icon(size, radius_ratio=0.2237):
    """The app icon, masked with the corner radius iOS uses, at `size` square."""
    icon = Image.open(ICON).convert("RGB").resize((size, size), Image.LANCZOS)
    radius = max(1, round(size * radius_ratio))
    # Build the mask at 4x and downsample: a rounded rectangle drawn straight at 32px is jagged.
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size * scale - 1, size * scale - 1), radius=radius * scale, fill=255)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(icon, (0, 0), mask)
    return out


def build_shots():
    written = []
    for source, name, top, bottom, width in SHOTS:
        im = Image.open(os.path.join(ROOT, source)).convert("RGB")
        im = im.crop((0, top, im.width, min(bottom, im.height)))
        height = round(im.height * width / im.width)
        im = im.resize((width, height), Image.LANCZOS)
        path = os.path.join(OUT, name + ".webp")
        im.save(path, "WEBP", quality=86, method=6)
        written.append((name + ".webp", im.size, os.path.getsize(path)))

    source, name, width = IPAD
    im = Image.open(os.path.join(ROOT, source)).convert("RGB")
    height = round(im.height * width / im.width)
    im = im.resize((width, height), Image.LANCZOS)
    path = os.path.join(OUT, name + ".webp")
    im.save(path, "WEBP", quality=86, method=6)
    written.append((name + ".webp", im.size, os.path.getsize(path)))
    return written


def build_icons():
    written = []
    for size in (32, 180, 512):
        icon = rounded_icon(size)
        path = os.path.join(OUT, "icon-%d.png" % size)
        icon.save(path, "PNG", optimize=True)
        written.append(("icon-%d.png" % size, icon.size, os.path.getsize(path)))
    return written


def build_og():
    """The 1200x630 social preview: the icon, the name, the one-line claim, the dashboard.

    PNG rather than WebP on purpose — several link previewers still refuse WebP.
    """
    w, h = 1200, 630
    card = Image.new("RGB", (w, h), (8, 11, 18))

    # A quiet vertical wash rather than a flat fill.
    top, bottom = (14, 26, 56), (6, 9, 16)
    draw = ImageDraw.Draw(card)
    for y in range(h):
        t = y / (h - 1)
        draw.line([(0, y), (w, y)],
                  fill=tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))

    semibold = os.path.join(FONT_DIR, "Inter-SemiBold.ttf")
    name_font = ImageFont.truetype(semibold, 78)
    line_font = ImageFont.truetype(semibold, 35)
    tag_font = ImageFont.truetype(semibold, 29)
    small_font = ImageFont.truetype(semibold, 27)

    icon = rounded_icon(132)
    card.paste(icon, (80, 96), icon)

    draw.text((238, 116), "CoreCredit", font=name_font, fill=(255, 255, 255))
    draw.text((240, 208), "Core charges, tracked to the credit",
              font=tag_font, fill=(150, 168, 205))

    body = [
        "Know exactly how much core money",
        "is still sitting with your vendors.",
    ]
    y = 300
    for line in body:
        draw.text((80, y), line, font=line_font, fill=(226, 234, 248))
        y += 52

    draw.rounded_rectangle((80, 452, 468, 510), radius=29, fill=ACCENT)
    draw.text((112, 467), "Now on the App Store", font=small_font, fill=(255, 255, 255))
    draw.text((80, 548), "Idlery Services LLC  ·  corecredit.idlery.com",
              font=small_font, fill=(126, 142, 176))

    # The dashboard capture, bled off the right edge inside a light bezel.
    shot = Image.open(os.path.join(ROOT, "Dashboard_Marketing.png")).convert("RGB")
    shot = shot.crop((0, 80, shot.width, 2012))
    sw = 372
    shot = shot.resize((sw, round(shot.height * sw / shot.width)), Image.LANCZOS)
    radius = 34
    mask = Image.new("L", (shot.width * 4, shot.height * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, shot.width * 4 - 1, shot.height * 4 - 1), radius=radius * 4, fill=255)
    mask = mask.resize(shot.size, Image.LANCZOS)

    bezel_pad = 11
    bezel = Image.new("RGBA", (shot.width + bezel_pad * 2, shot.height + bezel_pad * 2), (0, 0, 0, 0))
    ImageDraw.Draw(bezel).rounded_rectangle(
        (0, 0, bezel.width - 1, bezel.height - 1), radius=radius + bezel_pad, fill=(30, 41, 62, 255))
    card.paste(bezel, (742, 92), bezel)
    card.paste(shot, (742 + bezel_pad, 92 + bezel_pad), mask)

    path = os.path.join(OUT, "og.png")
    card.save(path, "PNG", optimize=True)
    return [("og.png", card.size, os.path.getsize(path))]


def main():
    if not os.path.isdir(OUT):
        os.makedirs(OUT)
    written = build_shots() + build_icons() + build_og()
    print("wrote into web/src/assets/:")
    total = 0
    for name, size, nbytes in written:
        total += nbytes
        print("  %-20s %-12s %7.1f KB" % (name, "%dx%d" % size, nbytes / 1024.0))
    print("  %-20s %-12s %7.1f KB" % ("(total)", "", total / 1024.0))


if __name__ == "__main__":
    main()
