#!/usr/bin/env python3
"""Render the launch screen's image from the CoreCredit mark and the Idlery wordmark.

    python3 scripts/render_launch_mark.py

# Why the credit is baked into the image

`UILaunchScreen` in `Config/CoreCredit-Info.plist` is a fixed recipe: one background colour and one
centred image. It has no text and no second image, and iOS gives no other knobs. So "Powered by
idlery" cannot be a label — it has to be part of the one image the launch screen is allowed to
draw, which is what this script builds.

The same limitation is why the credit sits below the mark rather than pinned to the bottom of the
screen: the image is centred at its natural size, so the only way to place something lower is to
make the image taller and let the centring push it down. It lands around three-quarters of the way
down on every current iPhone, which is as close to "bottom" as a static launch screen gets.

# Why white

The launch background is `#0053FD`. The wordmark's own teal reads at about 2:1 against it and black
is worse, so both the credit line and the wordmark are drawn in white. The letterforms are the
owner's artwork, unchanged — only the ink colour differs, which is what any logo does on a dark
brand ground.

Everything is rendered at 3x and downsampled, so the 1x and 2x assets are not separately hinted
approximations of a different drawing.
"""

import io
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Both inputs live outside the app target, so nothing here is bundled and — more importantly —
# the mark is read from its own pristine copy rather than from the imageset this script writes.
# Reading the output as the input works exactly once and quietly ruins the artwork on the second
# run, which is what happened the first time this was written.
SOURCE_WORDMARK = os.path.join(ROOT, "logo_name.jpg")
SOURCE_MARK = os.path.join(ROOT, "scripts", "branding", "corecredit-mark@3x.png")
MARK_SET = os.path.join(ROOT, "CoreCredit", "Resources", "Assets.xcassets", "LaunchMark.imageset")
FONT = "/mnt/skills/examples/canvas-design/canvas-fonts/Outfit-Regular.ttf"

# Points, at 1x. The mark is the existing artwork's size and is not resized.
MARK_POINTS = 320
GAP_POINTS = 84          # mark to credit line — what pushes the credit down the screen
WORDMARK_POINTS = 19     # full height of the wordmark including the y's descender
CREDIT_POINTS = 12.5     # cap height of "Powered by"
CREDIT_GAP_POINTS = 5    # "Powered by" to the wordmark

SCALE = 3                # everything is drawn here, then downsampled


def ink_alpha(image):
    """Turns a wordmark printed on white into white glyphs on transparency.

    Alpha is taken from how dark each pixel is rather than from a threshold, so the artwork's
    antialiased edges survive instead of turning into a staircase.
    """
    grey = image.convert("L")
    darkest = min(grey.getflattened_data() if hasattr(grey, "getflattened_data") else grey.getdata())

    # Solid ink has to land on a fully opaque 255, not on "nearly". The source is a JPEG, so its
    # flat areas wobble by a few levels and a straight linear ramp leaves the wordmark a shade
    # softer than the text beside it. Pulling the ends in by a margin saturates the solid areas and
    # still leaves the antialiased edges in between.
    margin = 10
    span = max(1, (255 - darkest) - 2 * margin)

    alpha = grey.point(
        lambda value: max(0, min(255, int((255 - value - margin) * 255 / span)))
    )
    white = Image.new("RGBA", image.size, (255, 255, 255, 255))
    white.putalpha(alpha)
    return white.crop(alpha.getbbox())


def build():
    wordmark = ink_alpha(Image.open(SOURCE_WORDMARK).convert("RGB"))

    mark = Image.open(SOURCE_MARK).convert("RGBA")
    mark_side = MARK_POINTS * SCALE
    if mark.size != (mark_side, mark_side):
        mark = mark.resize((mark_side, mark_side), Image.LANCZOS)

    # The credit line: "Powered by" set in Outfit, then the wordmark at a matched height.
    wordmark_height = int(WORDMARK_POINTS * SCALE)
    wordmark_width = max(1, round(wordmark.width * wordmark_height / wordmark.height))
    wordmark = wordmark.resize((wordmark_width, wordmark_height), Image.LANCZOS)

    font = ImageFont.truetype(FONT, int(CREDIT_POINTS * SCALE))
    ruler = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    text_box = ruler.textbbox((0, 0), "Powered by", font=font)
    text_width = text_box[2] - text_box[0]
    text_height = text_box[3] - text_box[1]

    credit_gap = int(CREDIT_GAP_POINTS * SCALE)
    credit_width = text_width + credit_gap + wordmark_width
    credit_height = max(text_height, wordmark_height)

    # Empty space above the mark, exactly matching what the credit adds below it. The launch
    # screen centres this image, so without the padding the mark would ride fifty points higher
    # than it does today — a visible change to a screen nobody asked to move. With it, the mark
    # stays where it has always been and only the credit is new.
    below = int(GAP_POINTS * SCALE) + credit_height

    canvas_width = mark_side
    canvas_height = below + mark_side + below
    canvas = Image.new("RGBA", (canvas_width, canvas_height), (0, 0, 0, 0))
    canvas.alpha_composite(mark, (0, below))

    credit_left = (canvas_width - credit_width) // 2
    credit_top = canvas_height - credit_height

    # Optically centred on the wordmark rather than aligned to a baseline the wordmark does not
    # share: it is artwork, not type, and its descender sits below where a cap-height run of text
    # would end.
    draw = ImageDraw.Draw(canvas)
    draw.text((credit_left - text_box[0],
               credit_top + (credit_height - text_height) // 2 - text_box[1]),
              "Powered by",
              font=font,
              fill=(255, 255, 255, 225))
    canvas.alpha_composite(wordmark,
                           (credit_left + text_width + credit_gap,
                            credit_top + (credit_height - wordmark_height) // 2))

    written = []
    for scale, name in ((3, "LaunchMark@3x.png"), (2, "LaunchMark@2x.png"), (1, "LaunchMark.png")):
        size = (round(canvas_width * scale / SCALE), round(canvas_height * scale / SCALE))
        out = canvas if scale == SCALE else canvas.resize(size, Image.LANCZOS)
        path = os.path.join(MARK_SET, name)
        out.save(path, "PNG")
        written.append((name, out.size, os.path.getsize(path)))

    print("rendered into CoreCredit/Resources/Assets.xcassets/LaunchMark.imageset/:")
    for name, size, byte_count in written:
        print("  %-18s %sx%s  %d bytes" % (name, size[0], size[1], byte_count))

    return canvas


def preview(canvas, path):
    """A 390x844 mock of the launch screen, for looking at rather than for shipping."""
    screen = Image.new("RGBA", (390 * 3, 844 * 3), (0x00, 0x53, 0xFD, 255))
    shown = canvas.resize((canvas.width // SCALE * 3, canvas.height // SCALE * 3), Image.LANCZOS)
    screen.alpha_composite(shown,
                           ((screen.width - shown.width) // 2,
                            (screen.height - shown.height) // 2))
    screen.convert("RGB").save(path, "PNG")
    print("preview written to %s" % path)


if __name__ == "__main__":
    import sys
    art = build()
    if len(sys.argv) > 1:
        preview(art, sys.argv[1])
