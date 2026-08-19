#!/usr/bin/env python3
"""Build the CoreCredit App Store screenshots from the committed source assets.

    python3 marketing/appstore/tools/build.py

Run from the repository root. Reads only the committed sources -- the raw
captures (Dashboard.png, Cores.png) and the Image 3 template layers -- and
writes the marketing captures plus the finished composite. Nothing it reads is
ever overwritten.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import statusbar
import bottom_cleanup
import compose

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
REFERENCE = "Dashboard.png"          # status-bar treatment is measured from this
# refine_tab_bar also rebuilds the translucent bar's material and the ghosting
# hugging its outer edge. Image 3's capture is built with it; the Dashboard
# capture is the visual reference the gallery is matched against and is left
# exactly as it was finalized.
CAPTURES = {"Cores.png": ("Cores_Marketing.png", True),
            "Dashboard.png": ("Dashboard_Marketing.png", False)}
TEMPLATE_BG = "CoreCredit_AppStore_03_Refined_Background.png"
TEMPLATE_OV = "CoreCredit_AppStore_03_Refined_Device_Overlay.png"
OUTPUT = "CoreCredit_AppStore_03_Track_Every_Core.png"
EXPECTED_CANVAS = (1290, 2796)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fonts", default=FONTS,
                    help="directory holding Inter-SemiBold.ttf (status-bar numerals)")
    args = ap.parse_args()

    os.chdir(ROOT)
    report = {}

    for src, (dst, refine) in CAPTURES.items():
        tmp = dst + ".statusbar.tmp.png"
        report[dst] = {
            "status_bar": statusbar.finalize(src, REFERENCE, tmp, args.fonts),
            "bottom_edge": bottom_cleanup.clean(tmp, dst, refine_tab_bar=refine),
        }
        os.remove(tmp)

    report[OUTPUT] = compose.compose(TEMPLATE_BG, TEMPLATE_OV,
                                     "Cores_Marketing.png", OUTPUT)
    if tuple(report[OUTPUT]["canvas"]) != EXPECTED_CANVAS:
        raise SystemExit(f"canvas is {report[OUTPUT]['canvas']}, expected {EXPECTED_CANVAS}")

    print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
