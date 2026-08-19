#!/usr/bin/env python3
"""Build the CoreCredit App Store screenshots from the committed source assets.

    python3 marketing/appstore/tools/build.py

Run from the repository root. Reads only the committed sources -- the raw
captures and the template layers -- and writes the marketing captures plus the
finished composites. Nothing it reads is ever overwritten.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import statusbar
import top_cleanup
import bottom_cleanup
import compose

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
FONTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fonts")
REFERENCE = "Dashboard.png"          # status-bar treatment is measured from this
# Each capture, and what its screen needs cleaning of beyond the status bar.
# `top` lifts a previous section blurred under the navigation bar; `separator`
# is the first row below the last full list row; `through_bar` also evens out a
# next-section card that reads through the floating tab bar.
CAPTURES = {
    "Cores.png": dict(out="Cores_Marketing.png"),
    "Dashboard.png": dict(out="Dashboard_Marketing.png"),
    "image4.PNG": dict(out="Returns_Marketing.png", top=True,
                       separator=1816, through_bar=True),
}
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

    for src, spec in CAPTURES.items():
        dst = spec["out"]
        step = src
        entry = report[dst] = {}
        if spec.get("top"):
            step = dst + ".top.tmp.png"
            entry["top_edge"] = top_cleanup.clean(src, step)
        bar = dst + ".statusbar.tmp.png"
        entry["status_bar"] = statusbar.finalize(step, REFERENCE, bar, args.fonts)
        entry["bottom_edge"] = bottom_cleanup.clean(
            bar, dst, separator_y=spec.get("separator", bottom_cleanup.SEPARATOR_Y),
            through_bar=spec.get("through_bar", False))
        for tmp in (step, bar):
            if tmp != src:
                os.remove(tmp)

    report[OUTPUT] = compose.compose(TEMPLATE_BG, TEMPLATE_OV,
                                     "Cores_Marketing.png", OUTPUT)
    if tuple(report[OUTPUT]["canvas"]) != EXPECTED_CANVAS:
        raise SystemExit(f"canvas is {report[OUTPUT]['canvas']}, expected {EXPECTED_CANVAS}")

    print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
