"""
Build the four finished iPad App Store images.

    python3 marketing/appstore/tools/ipad/finish.py        # from the repo root

Reads the raw captures committed at `marketing/appstore/ipad/screenshots/`,
applies the cleanup in `clean.py`, and lays each one into the matching plate
rendered by `build.mjs`.

The capture is 2360 x 1640 and the aperture is 1475 x 1025 — the same aspect —
so the placement is a single uniform x0.625 scale. Nothing is stretched and
nothing is cropped.
"""

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import clean  # noqa: E402

ROOT = Path(__file__).resolve().parents[4]
SHOTS = ROOT / 'marketing/appstore/ipad/screenshots'
OUT = ROOT / 'marketing/appstore/ipad'
PLATES = OUT / '_plates'

# plate slug -> (output index, cleaned capture key)
FINALS = [
    ('dashboard', 1, 'dashboard'),
    ('cores',     2, 'cores'),
    ('returns',   3, 'returns'),
    ('timeline',  4, 'alternator'),
]


def rounded_mask(w, h, r, ss=4):
    """Anti-aliased rounded-rectangle mask, built oversampled then reduced."""
    m = Image.new('L', (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [0, 0, w * ss - 1, h * ss - 1], radius=r * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def main():
    spec = json.loads((OUT / 'template-spec.json').read_text())
    ap = spec['screenAperture']
    cap = spec['captureSize']
    scale = spec['scaleFromCapture']

    cleaned = clean.clean_all(SHOTS)
    mask = rounded_mask(ap['width'], ap['height'], ap['cornerRadius'])

    for slug, idx, key in FINALS:
        shot = cleaned[key]
        if shot.size != (cap['width'], cap['height']):
            raise SystemExit(f'{key}: expected {cap["width"]}x{cap["height"]}, got {shot.size}')

        target = (ap['width'], ap['height'])
        exact = (round(shot.width * scale), round(shot.height * scale))
        if exact != target:
            raise SystemExit(f'{key}: uniform scale gives {exact}, aperture is {target}')

        fitted = shot.resize(target, Image.LANCZOS)
        plate = Image.open(PLATES / f'{slug}.png').convert('RGB')
        plate.paste(fitted, (ap['x'], ap['y']), mask)

        dst = OUT / f'CoreCredit_iPad_AppStore_{idx:02d}_{slug}.png'
        plate.save(dst)
        print(f'  {dst.name}  {plate.size}  capture scaled x{scale} '
              f'({shot.width}x{shot.height} -> {target[0]}x{target[1]})')


if __name__ == '__main__':
    main()
