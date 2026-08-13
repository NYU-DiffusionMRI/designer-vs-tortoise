#!/usr/bin/env python
"""
compare_maps.py

Minimal voxel-wise comparison of 3D FA/MD/MW maps from a "designer + tmi"
params/ directory vs a "tortoise + tmi" params/ directory (both produced by
run_tmi.sh). Uses fa_dki.nii and md_dki.nii (DKI fit) and mk_wdki.nii
(WDKI fit, abbreviated MW here) so MW reflects the weighted-DKI mean
kurtosis estimate. No resampling is performed -- each map pair must already
share the same shape and affine. Comparisons are restricted to a common
brain mask (--mask).

Usage:
    python compare_maps.py output/designer_denoise/params output/tortoise_denoise/params \
        --output-dir results/ --label "DESIGNER vs TORTOISE - denoising maps"

--mask defaults to the common BET brain mask produced by extract_brain_mask.sh
(output/brain_mask/brain_mask.nii.gz).

--fa-range / --md-range / --mw-range set the x-axis / histogram range for
each map's panel in the combined distribution plot (defaults: FA 0-0.1,
MD 0-0.2, MW 0-0.5).

Each run writes into its own timestamped subfolder of --output-dir (so repeat
runs never clobber each other):
    <output-dir>/<timestamp>[_<slugified-label>]/summary_metrics.csv
    <output-dir>/<timestamp>[_<slugified-label>]/abs_diff_<MAP>.nii.gz
    <output-dir>/<timestamp>[_<slugified-label>]/map_diff_distribution.png

summary_metrics.csv has one row per map (FA, MD, MW): label, timestamp, map,
designer_img, tortoise_img, then MAD, RMSE, max abs diff, Pearson r, and
per-image mean/std/median -- all computed within the brain mask.
abs_diff_<MAP>.nii.gz: voxel-wise |designer - tortoise| for that map (full
volume, not restricted to the mask).
map_diff_distribution.png: 1x3 grid, one histogram of masked abs(diff) per
map, each with its own x-axis range.
"""

import argparse
from datetime import datetime
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np
import pandas as pd

from compare_common import (
    build_mask,
    compute_metrics,
    load_and_validate,
    load_spatial_reference,
    print_summary,
    slugify,
)

MAP_FILENAMES = {
    "FA": "fa_dki.nii",
    "MD": "md_dki.nii",
    "MW": "mk_wdki.nii",
}

DEFAULT_RANGES = {
    "FA": (0.0, 0.1),
    "MD": (0.0, 0.2),
    "MW": (0.0, 0.5),
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare 3D FA/MD/MW maps from a designer+tmi params/ dir vs a tortoise+tmi params/ dir."
    )
    parser.add_argument("designer_params_dir", type=Path, help="params/ dir from designer + tmi")
    parser.add_argument("tortoise_params_dir", type=Path, help="params/ dir from tortoise + tmi")
    parser.add_argument(
        "--mask",
        type=Path,
        default=Path("output/brain_mask/brain_mask.nii.gz"),
        help="Common BET brain mask NIfTI (default: output/brain_mask/brain_mask.nii.gz)",
    )
    parser.add_argument(
        "--fa-range",
        type=float,
        nargs=2,
        default=DEFAULT_RANGES["FA"],
        metavar=("MIN", "MAX"),
        help="Histogram/x-axis range for the FA diff panel (default: 0.0 0.1)",
    )
    parser.add_argument(
        "--md-range",
        type=float,
        nargs=2,
        default=DEFAULT_RANGES["MD"],
        metavar=("MIN", "MAX"),
        help="Histogram/x-axis range for the MD diff panel (default: 0.0 0.2)",
    )
    parser.add_argument(
        "--mw-range",
        type=float,
        nargs=2,
        default=DEFAULT_RANGES["MW"],
        metavar=("MIN", "MAX"),
        help="Histogram/x-axis range for the MW (mk_wdki) diff panel (default: 0.0 0.5)",
    )
    parser.add_argument("--bins", type=int, default=100, help="Number of histogram bins (default: 100)")
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("results/"),
        help="Parent directory for the timestamped run folder (default: ./results/)",
    )
    parser.add_argument(
        "--label",
        type=str,
        default="",
        help="Short description of the comparison, e.g. 'DESIGNER vs TORTOISE - denoising maps'. "
        "Included in the run directory name and the summary CSV.",
    )
    return parser.parse_args()


def resolve_map_path(params_dir: Path, filename: str) -> Path:
    path = params_dir / filename
    if not path.is_file():
        raise FileNotFoundError(f"Expected map file not found: {path}")
    return path


def main():
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    map_ranges = {"FA": tuple(args.fa_range), "MD": tuple(args.md_range), "MW": tuple(args.mw_range)}

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir_name = timestamp if not args.label else f"{timestamp}_{slugify(args.label)}"
    run_dir = args.output_dir / run_dir_name
    run_dir.mkdir(parents=True)
    print(f"Run directory: {run_dir}")

    brain_mask = None
    rows = []
    fig, axes = plt.subplots(1, 3, figsize=(15, 5))
    for (map_name, filename), ax in zip(MAP_FILENAMES.items(), axes):
        designer_img = resolve_map_path(args.designer_params_dir, filename)
        tortoise_img = resolve_map_path(args.tortoise_params_dir, filename)

        nii1, nii2, data1, data2 = load_and_validate(designer_img, tortoise_img)
        if brain_mask is None:
            brain_mask = load_spatial_reference(args.mask, data1.shape) > 0
        mask = build_mask(data1, data2) & brain_mask

        metrics = compute_metrics(data1, data2, mask, label=map_name)
        metrics = {
            "label": args.label,
            "timestamp": timestamp,
            "map": map_name,
            "designer_img": str(designer_img),
            "tortoise_img": str(tortoise_img),
            **metrics,
        }
        print_summary(metrics)
        rows.append(metrics)

        diff_img = nib.Nifti1Image(np.abs(data1 - data2), nii1.affine, nii1.header)
        diff_path = run_dir / f"abs_diff_{map_name}.nii.gz"
        nib.save(diff_img, diff_path)
        print(f"Wrote {diff_path}")

        abs_diff = np.abs(data1 - data2)[mask]
        map_range = map_ranges[map_name]
        ax.hist(abs_diff, bins=args.bins, range=map_range, color="steelblue", edgecolor="none")
        ax.axvline(abs_diff.mean(), color="firebrick", linestyle="--", label=f"mean = {abs_diff.mean():.4g}")
        ax.axvline(
            np.median(abs_diff), color="darkorange", linestyle="--", label=f"median = {np.median(abs_diff):.4g}"
        )
        ax.set_xlim(map_range)
        ax.set_xlabel("|designer - tortoise|")
        ax.set_ylabel("Voxel count")
        ax.set_title(map_name)
        ax.legend()

    fig.suptitle(args.label or "DESIGNER vs TORTOISE - map diffs")
    fig.tight_layout()
    plot_path = run_dir / "map_diff_distribution.png"
    fig.savefig(plot_path, dpi=150)
    plt.close(fig)
    print(f"Wrote {plot_path}")

    df = pd.DataFrame(rows)
    csv_path = run_dir / "summary_metrics.csv"
    df.to_csv(csv_path, index=False)
    print(f"Wrote {csv_path}")


if __name__ == "__main__":
    main()
