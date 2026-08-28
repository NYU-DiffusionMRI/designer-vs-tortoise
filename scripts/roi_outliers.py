#!/usr/bin/env python
"""
roi_outliers.py

Minimal ROI-level outlier report for a roi_means.csv file produced by
compare_maps_roi.py (columns: label, map, n_voxels, designer_mean,
tortoise_mean). For each (label, map) row, computes the percent difference
between designer_mean and tortoise_mean, designer treated as reference:

    pct_diff = |designer_mean - tortoise_mean| / designer_mean * 100

and reports rows at or above --threshold percent, sorted by pct_diff
descending, with a human-readable anatomical ROI name attached to each row
(looked up from a FreeSurferColorLUT.txt via --lut, defaulting to
$FREESURFER_HOME/FreeSurferColorLUT.txt -- run 'module load freesurfer'
first, or pass --lut explicitly. Falls back to 'label-<n>' if no LUT is
available).

Usage (from the project root, with the freesurfer module loaded):
    module load freesurfer
    python scripts/roi_outliers.py results/20260828_171532_full_processing_roi_means/roi_means.csv \
        --threshold 5.0 --output results/roi_outliers.csv

Prints the outlier rows to stdout as a minimal table (label, roi_name, map,
n_voxels, designer_mean, tortoise_mean, pct_diff), and writes them to
--output as CSV if given (default: print only). Rows where designer_mean is
near zero (percent difference undefined) are excluded and counted in a
printed warning line.
"""

import argparse
import os
from pathlib import Path

import pandas as pd

from dwicompare.compare_common import load_roi_lut

DEFAULT_THRESHOLD = 5.0
ZERO_EPS = 1e-9

# Default LUT: $FREESURFER_HOME/FreeSurferColorLUT.txt if the freesurfer
# module is loaded, else None (roi_name falls back to "label-<n>").
_fs_home = os.environ.get("FREESURFER_HOME")
DEFAULT_LUT = Path(_fs_home) / "FreeSurferColorLUT.txt" if _fs_home else None


def parse_args():
    parser = argparse.ArgumentParser(
        description="Flag roi_means.csv rows where designer_mean and tortoise_mean differ a lot."
    )
    parser.add_argument("csv_path", type=Path, help="roi_means.csv from compare_maps_roi.py")
    parser.add_argument(
        "--threshold",
        type=float,
        default=DEFAULT_THRESHOLD,
        metavar="PCT",
        help=f"Flag rows at or above this percent difference (default: {DEFAULT_THRESHOLD})",
    )
    parser.add_argument(
        "--lut",
        type=Path,
        default=DEFAULT_LUT,
        help="FreeSurferColorLUT.txt-format file for ROI names "
        "(default: $FREESURFER_HOME/FreeSurferColorLUT.txt if set, else none -- "
        "run 'module load freesurfer' or pass this explicitly)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Optional CSV path to also save the flagged rows (default: print only)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    df = pd.read_csv(args.csv_path)

    lut = load_roi_lut(args.lut)
    if not lut:
        print(
            f"Warning: no ROI name lookup available (--lut={args.lut}); "
            "showing raw label ids. Run 'module load freesurfer' or pass --lut."
        )

    zero_denom = df["designer_mean"].abs() <= ZERO_EPS
    df["pct_diff"] = (df["designer_mean"] - df["tortoise_mean"]).abs() / df["designer_mean"] * 100
    df.loc[zero_denom, "pct_diff"] = float("nan")
    if zero_denom.any():
        print(f"Skipping {int(zero_denom.sum())} row(s) with near-zero designer_mean (pct diff undefined)")

    df["roi_name"] = df["label"].apply(lambda n: lut.get(int(n), f"label-{int(n)}"))

    outliers = df[df["pct_diff"] >= args.threshold].sort_values("pct_diff", ascending=False)
    columns = ["label", "roi_name", "map", "n_voxels", "designer_mean", "tortoise_mean", "pct_diff"]

    print(f"\n{len(outliers)} row(s) at or above {args.threshold}% difference:\n")
    print(outliers[columns].round(4).to_string(index=False) if not outliers.empty else "(none)")

    if args.output is not None:
        outliers[columns].to_csv(args.output, index=False)
        print(f"\nWrote {args.output}")


if __name__ == "__main__":
    main()
