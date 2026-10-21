"""Fit a white-balance reference from corresponding neutral object patches.

ROIs are normalized x0 y0 x1 y1, independently chosen in the phone and board
images. Use the SAME object under the SAME light, excluding reflections/text.
This fits appearance balance at one reference point, not absolute lamp CCT or a
full colour-correction matrix. --apply updates the profile; regenerate/rebuild
the FPGA after reviewing the report.
"""
import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image
from color_model import PROFILE_PATH, load_profile


def patch_ratios(path, roi):
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=float)
    h, w = rgb.shape[:2]
    x0, y0, x1, y1 = roi
    if not (0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1):
        raise ValueError("ROI must be inside the image and have positive area")
    patch = rgb[int(y0*h):int(y1*h), int(x0*w):int(x1*w)].reshape(-1, 3)
    keep = (patch.min(axis=1) >= 16) & (patch.max(axis=1) <= 235)
    patch = patch[keep]
    if len(patch) < 100:
        raise ValueError("Not enough unclipped, non-dark pixels in the patch")
    ratios = np.median(patch[:, (0, 2)] / patch[:, 1, None], axis=0)
    return {"rg": float(ratios[0]), "bg": float(ratios[1]),
            "median_rgb": np.median(patch, axis=0).tolist(), "usable_pixels": len(patch)}


def fit_gains(reference, board, input_gains):
    if len(input_gains) != 3 or any(not 64 <= value <= 511 for value in input_gains):
        raise ValueError("Input gains must describe the actual bounded FPGA RGB settings")
    r, g, b = input_gains
    desired = (r * 256/g * reference["rg"]/board["rg"],
               256, b * 256/g * reference["bg"]/board["bg"])
    if any(v < 64 or v > 511 for v in desired):
        raise ValueError("Required gains exceed the FPGA range; check ROI, exposure and channel order")
    return [int(v + .5) for v in desired]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference", required=True)
    parser.add_argument("--board", required=True)
    parser.add_argument("--reference-roi", nargs=4, type=float, required=True)
    parser.add_argument("--board-roi", nargs=4, type=float, required=True)
    parser.add_argument("--input-gains", nargs=3, type=int, default=(256, 256, 256))
    parser.add_argument("--out", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    reference = patch_ratios(args.reference, args.reference_roi)
    board = patch_ratios(args.board, args.board_roi)
    fitted = fit_gains(reference, board, args.input_gains)
    result = {"reference": str(Path(args.reference).resolve()), "board": str(Path(args.board).resolve()),
              "reference_roi": args.reference_roi, "board_roi": args.board_roi,
              "reference_patch": reference, "board_patch": board,
              "input_gains_q8": args.input_gains, "fitted_gains_q8": fitted,
              "scope": "single-scene appearance white balance; not a measured colour temperature"}
    Path(args.out).write_text(json.dumps(result, indent=2), encoding="utf-8")
    if args.apply:
        profile = load_profile()
        profile["base_gains_q8"] = fitted
        profile["calibration_status"] = "single-scene phone reference fitted; hardware comparison pending"
        PROFILE_PATH.write_text(json.dumps(profile, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
