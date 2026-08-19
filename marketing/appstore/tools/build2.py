#!/usr/bin/env python3
"""Build CoreCredit App Store Image 2 from the committed source assets.

    python3 marketing/appstore/tools/build2.py

Run from the repository root. Reads only committed sources -- the two sheet
captures, the reference capture the gallery's status bar is measured from, and
Image 3's finished layers -- and writes only new files. Nothing it reads is
overwritten.

It prints a JSON report of every measurement it made: the sheet repair applied
to each capture, the backdrop fit against Image 3, where the copy was set, and
each phone's scale, crop and placement. A rebuild can be checked against the
numbers in the commit that introduced it.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sheet_cleanup
import copydeck
import image2

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
REFERENCE = "Dashboard_Marketing.png"       # the gallery's finished status bar
IMAGE3_BG = "CoreCredit_AppStore_03_Refined_Background.png"
MARKETING = {"lefttiltedphone.PNG": "lefttiltedphone_Marketing.png",
             "rightherophone.PNG": "rightherophone_Marketing.png"}
OUT_BG = "CoreCredit_AppStore_02_Refined_Background.png"
OUT_TEMPLATE = "CoreCredit_AppStore_02_Refined_Template.png"
OUT_FINAL = "CoreCredit_AppStore_02_Capture_A_Core.png"
EXPECTED_CANVAS = (1290, 2796)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--supersample", type=int, default=3,
                    help="device frames are drawn at this factor, then resolved down")
    args = ap.parse_args()

    os.chdir(ROOT)
    report = {}

    for src, dst in MARKETING.items():
        report[dst] = sheet_cleanup.clean(src, REFERENCE, dst, sheet_cleanup.SOURCES[src])

    report["typesetting_check"] = copydeck.verify(IMAGE3_BG)["ink_iou"]
    report[OUT_FINAL] = image2.compose(
        IMAGE3_BG, MARKETING["lefttiltedphone.PNG"], MARKETING["rightherophone.PNG"],
        OUT_BG, OUT_TEMPLATE, OUT_FINAL, ss=args.supersample)

    if tuple(report[OUT_FINAL]["canvas"]) != EXPECTED_CANVAS:
        raise SystemExit(f"canvas is {report[OUT_FINAL]['canvas']}, expected {EXPECTED_CANVAS}")

    print(json.dumps(report, indent=2, default=str))


if __name__ == "__main__":
    main()
