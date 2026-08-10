#!/usr/bin/env python
"""
compare_dwi.py

Minimal voxel-wise comparison of two 4D diffusion MRI NIfTI images (e.g. a
DESIGNER pipeline output vs a TORTOISE pipeline output covering the same
acquisition). No resampling is performed -- both images must already share
the same shape and affine.

Usage:
    python compare_dwi.py designer_output.nii.gz tortoise_output.nii.gz \
        --output-dir results/ --label "DESIGNER vs TORTOISE - denoising"

Each run writes into its own timestamped subfolder of --output-dir (so repeat
runs never clobber each other):
    <output-dir>/<timestamp>[_<slugified-label>]/summary_metrics.csv
    <output-dir>/<timestamp>[_<slugified-label>]/abs_diff.nii.gz

summary_metrics.csv columns: label, timestamp, img1, img2, then MAD, RMSE,
max abs diff, Pearson r, and per-image mean/std/median.
abs_diff.nii.gz: voxel-wise |img1 - img2|, full 4D, img1's affine.
"""

import argparse
from datetime import datetime
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd

from compare_common import build_mask, compute_metrics, load_and_validate, print_summary, slugify


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare two 4D diffusion MRI NIfTI images voxel-wise."
    )
    parser.add_argument("img1", type=Path, help="First NIfTI image (e.g. DESIGNER output)")
    parser.add_argument("img2", type=Path, help="Second NIfTI image (e.g. TORTOISE output)")
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
        help="Short description of the comparison, e.g. 'DESIGNER vs TORTOISE - denoising'. "
        "Included in the run directory name and the summary CSV.",
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

    nii1, nii2, data1, data2 = load_and_validate(args.img1, args.img2)
    mask = build_mask(data1, data2)

    metrics = compute_metrics(data1, data2, mask, label="raw")
    metrics = {
        "label": args.label,
        "timestamp": timestamp,
        "img1": str(args.img1),
        "img2": str(args.img2),
        **metrics,
    }
    print_summary(metrics)

    df = pd.DataFrame([metrics])
    csv_path = run_dir / "summary_metrics.csv"
    df.to_csv(csv_path, index=False)

    diff_img = nib.Nifti1Image(np.abs(data1 - data2), nii1.affine, nii1.header)
    diff_path = run_dir / "abs_diff.nii.gz"
    nib.save(diff_img, diff_path)

    print(f"Wrote {csv_path}")
    print(f"Wrote {diff_path}")


if __name__ == "__main__":
    main()
