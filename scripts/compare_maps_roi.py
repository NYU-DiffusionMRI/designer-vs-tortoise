#!/usr/bin/env python
"""
compare_maps_roi.py

Minimal ROI-level comparison of 3D FA/MD/MW maps from a "designer + tmi"
params/ directory vs a "tortoise + tmi" params/ directory (both produced by
run_tmi.sh), summarized per anatomical ROI rather than per voxel.

ROIs come from a segmentation volume (default: output/samseg/seg2dwi.nii.gz)
that must share shape and affine with the maps -- voxels with the same label
value belong to the same ROI. Label 0 (background/unsegmented) is excluded.
For each ROI and each map, the mean value within that ROI is computed
separately for the designer and tortoise maps, giving one (x, y) point per
ROI: x = designer ROI mean, y = tortoise ROI mean.

Usage (from the project root):
    python scripts/compare_maps_roi.py output/designer_denoise/params output/tortoise_denoise/params \
        --output-dir results/ --label "DESIGNER vs TORTOISE - ROI means"

--fa-range/--md-range/--mw-range set the shared x/y axis range (and the span
of the y=x reference line) for each map's scatter panel (defaults:
FA 0.0-1.0, MD 0.0-3.0, MW 0.0-2.0).

Each run writes into its own timestamped subfolder of --output-dir (so repeat
runs never clobber each other):
    <output-dir>/<timestamp>[_<slugified-label>]/roi_means.csv
    <output-dir>/<timestamp>[_<slugified-label>]/roi_scatter.png

roi_means.csv has one row per (map, ROI label): label, map, n_voxels,
designer_mean, tortoise_mean.
roi_scatter.png: 1x3 grid, one scatter plot per map (FA/MD/MW), each point a
single ROI (x = designer mean, y = tortoise mean), with a y=x reference line.
"""

import argparse
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

from dwicompare.compare_common import (
    MAP_FILENAMES,
    load_and_validate,
    load_spatial_reference,
    resolve_map_path,
    slugify,
)

# Repo root, one level up from scripts/ -- anchors the CLI defaults below
# regardless of the caller's CWD. Computed locally (not imported from
# dwicompare) since it's a property of this repo layout, not of the package.
PROJECT_ROOT = Path(__file__).resolve().parent.parent

DEFAULT_FA_RANGE = (0.0, 1.0)
DEFAULT_MD_RANGE = (0.0, 3.0)
DEFAULT_MW_RANGE = (0.0, 2.0)


def concordance_correlation_coefficient(x: np.ndarray, y: np.ndarray) -> float:
    """Lin's CCC: agreement with the y=x line, not just linear correlation."""
    mean_x, mean_y = x.mean(), y.mean()
    var_x, var_y = x.var(), y.var()
    covariance = np.mean((x - mean_x) * (y - mean_y))
    return (2 * covariance) / (var_x + var_y + (mean_x - mean_y) ** 2)


def parse_args():
    parser = argparse.ArgumentParser(
        description="Scatter ROI-mean FA/MD/MW from a designer+tmi params/ dir vs a tortoise+tmi params/ dir."
    )
    parser.add_argument("designer_params_dir", type=Path, help="params/ dir from designer + tmi")
    parser.add_argument("tortoise_params_dir", type=Path, help="params/ dir from tortoise + tmi")
    parser.add_argument(
        "--seg",
        type=Path,
        default=PROJECT_ROOT / "output/samseg/seg2dwi.nii.gz",
        help="Segmentation NIfTI defining ROIs, same shape/affine as the maps "
        "(default: output/samseg/seg2dwi.nii.gz). Label 0 is excluded.",
    )
    parser.add_argument(
        "--fa-range",
        type=float,
        nargs=2,
        default=DEFAULT_FA_RANGE,
        metavar=("MIN", "MAX"),
        help="Shared x/y axis range for the FA scatter panel (default: 0.0 1.0)",
    )
    parser.add_argument(
        "--md-range",
        type=float,
        nargs=2,
        default=DEFAULT_MD_RANGE,
        metavar=("MIN", "MAX"),
        help="Shared x/y axis range for the MD scatter panel (default: 0.0 3.0)",
    )
    parser.add_argument(
        "--mw-range",
        type=float,
        nargs=2,
        default=DEFAULT_MW_RANGE,
        metavar=("MIN", "MAX"),
        help="Shared x/y axis range for the MW scatter panel (default: 0.0 2.0)",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=PROJECT_ROOT / "results",
        help="Parent directory for the timestamped run folder (default: <project root>/results/)",
    )
    parser.add_argument(
        "--label",
        type=str,
        default="",
        help="Short description of the comparison, e.g. 'DESIGNER vs TORTOISE - ROI means'. "
        "Included in the run directory name and the CSV.",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir_name = timestamp if not args.label else f"{timestamp}_{slugify(args.label)}"
    run_dir = args.output_dir / run_dir_name
    run_dir.mkdir(parents=True)
    print(f"Run directory: {run_dir}")

    plot_ranges = {
        "FA": tuple(args.fa_range),
        "MD": tuple(args.md_range),
        "MW": tuple(args.mw_range),
    }

    seg_data = None
    rows = []
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    for ax, (map_name, filename) in zip(axes, MAP_FILENAMES.items()):
        designer_img = resolve_map_path(args.designer_params_dir, filename)
        tortoise_img = resolve_map_path(args.tortoise_params_dir, filename)

        nii1, nii2, data1, data2 = load_and_validate(designer_img, tortoise_img)
        if seg_data is None:
            seg_data = load_spatial_reference(args.seg, data1.shape)
            roi_labels = sorted(int(v) for v in np.unique(seg_data) if v != 0)
            print(f"Found {len(roi_labels)} ROI labels (excluding background) in {args.seg}")

        finite = np.isfinite(data1) & np.isfinite(data2)

        xs, ys = [], []
        for label in roi_labels:
            roi_mask = finite & (seg_data == label)
            n_voxels = int(roi_mask.sum())
            if n_voxels == 0:
                print(f"  [{map_name}] label {label}: no finite voxels, skipping")
                continue
            x = data1[roi_mask].mean()
            y = data2[roi_mask].mean()
            xs.append(x)
            ys.append(y)
            rows.append(
                {
                    "label": label,
                    "map": map_name,
                    "n_voxels": n_voxels,
                    "designer_mean": x,
                    "tortoise_mean": y,
                }
            )

        xs, ys = np.array(xs), np.array(ys)
        ccc = concordance_correlation_coefficient(xs, ys) if xs.size >= 2 else float("nan")

        lo, hi = plot_ranges[map_name]
        ax.scatter(xs, ys, color="steelblue", edgecolor="none")
        ax.plot([lo, hi], [lo, hi], color="firebrick", linestyle="--", label="y = x")
        ax.set_xlim(lo, hi)
        ax.set_ylim(lo, hi)
        ax.set_xlabel("DESIGNER ROI mean")
        ax.set_ylabel("TORTOISE ROI mean")
        ax.set_title(f"{map_name} (n={xs.size} ROIs, CCC={ccc:.4f})")
        ax.legend()

    fig.suptitle(args.label or "DESIGNER vs TORTOISE - ROI means")
    fig.tight_layout()
    plot_path = run_dir / "roi_scatter.png"
    fig.savefig(plot_path, dpi=150)
    plt.close(fig)
    print(f"Wrote {plot_path}")

    df = pd.DataFrame(rows)
    csv_path = run_dir / "roi_means.csv"
    df.to_csv(csv_path, index=False)
    print(f"Wrote {csv_path}")


if __name__ == "__main__":
    main()
