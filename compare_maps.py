#!/usr/bin/env python
"""
compare_maps.py

Minimal voxel-wise comparison of 3D FA/MD/MK maps from a "designer + tmi"
params/ directory vs a "tortoise + tmi" params/ directory (both produced by
run_tmi.sh). Uses the DKI-fit variant of each map (fa_dki.nii, md_dki.nii,
mk_dki.nii) so all three come from the same fit. No resampling is performed
-- each map pair must already share the same shape and affine.

Usage:
    python compare_maps.py output/designer_denoise/params output/tortoise_denoise/params \
        --output-dir results/ --label "DESIGNER vs TORTOISE - denoising maps"

Each run writes into its own timestamped subfolder of --output-dir (so repeat
runs never clobber each other):
    <output-dir>/<timestamp>[_<slugified-label>]/summary_metrics.csv
    <output-dir>/<timestamp>[_<slugified-label>]/abs_diff_<MAP>.nii.gz

summary_metrics.csv has one row per map (FA, MD, MK): label, timestamp, map,
designer_img, tortoise_img, then MAD, RMSE, max abs diff, Pearson r, and
per-image mean/std/median.
abs_diff_<MAP>.nii.gz: voxel-wise |designer - tortoise| for that map.
"""

import argparse
from datetime import datetime
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from compare_common import build_mask, compute_metrics, load_and_validate, print_summary, slugify

MAP_FILENAMES = {
    "FA": "fa_dki.nii",
    "MD": "md_dki.nii",
    "MK": "mk_dki.nii",
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare 3D FA/MD/MK maps from a designer+tmi params/ dir vs a tortoise+tmi params/ dir."
    )
    parser.add_argument("designer_params_dir", type=Path, help="params/ dir from designer + tmi")
    parser.add_argument("tortoise_params_dir", type=Path, help="params/ dir from tortoise + tmi")
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

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir_name = timestamp if not args.label else f"{timestamp}_{slugify(args.label)}"
    run_dir = args.output_dir / run_dir_name
    run_dir.mkdir(parents=True)
    print(f"Run directory: {run_dir}")

    rows = []
    for map_name, filename in MAP_FILENAMES.items():
        designer_img = resolve_map_path(args.designer_params_dir, filename)
        tortoise_img = resolve_map_path(args.tortoise_params_dir, filename)

        nii1, nii2, data1, data2 = load_and_validate(designer_img, tortoise_img)
        mask = build_mask(data1, data2)

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

    df = pd.DataFrame(rows)
    csv_path = run_dir / "summary_metrics.csv"
    df.to_csv(csv_path, index=False)
    print(f"Wrote {csv_path}")


if __name__ == "__main__":
    main()
