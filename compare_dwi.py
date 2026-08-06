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
import re
from datetime import datetime
from pathlib import Path

import nibabel as nib
import numpy as np
import pandas as pd
from scipy.stats import pearsonr


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


def slugify(text: str) -> str:
    """Lowercase, non-alphanumeric runs -> '_', trimmed. Used for directory names."""
    return re.sub(r"[^a-zA-Z0-9]+", "_", text).strip("_").lower()


def load_and_validate(path1: Path, path2: Path):
    """Load both images and check they share shape and affine (no resampling)."""
    nii1 = nib.load(path1)
    nii2 = nib.load(path2)

    if nii1.shape != nii2.shape:
        raise ValueError(
            f"Shape mismatch: {path1.name} has shape {nii1.shape}, "
            f"{path2.name} has shape {nii2.shape}."
        )
    if not np.allclose(nii1.affine, nii2.affine, atol=1e-4):
        raise ValueError(
            f"Affine mismatch between {path1.name} and {path2.name}. "
            "Images must be voxel-aligned; this script does not resample."
        )

    data1 = np.asarray(nii1.get_fdata(), dtype=np.float64)
    data2 = np.asarray(nii2.get_fdata(), dtype=np.float64)
    return nii1, nii2, data1, data2


def build_mask(data1: np.ndarray, data2: np.ndarray) -> np.ndarray:
    """Boolean mask excluding voxels where both images are zero, and any
    voxel where either image is NaN/Inf."""
    finite = np.isfinite(data1) & np.isfinite(data2)
    both_zero = (data1 == 0) & (data2 == 0)
    return finite & ~both_zero


def compute_metrics(data1: np.ndarray, data2: np.ndarray, mask: np.ndarray, label: str) -> dict:
    """Compute comparison metrics over the masked, flattened voxels."""
    v1 = data1[mask]
    v2 = data2[mask]
    diff = v1 - v2
    abs_diff = np.abs(diff)
    r, _ = pearsonr(v1, v2)

    return {
        "analysis": label,
        "n_voxels": v1.size,
        "mad": abs_diff.mean(),
        "rmse": np.sqrt(np.mean(diff ** 2)),
        "max_abs_diff": abs_diff.max(),
        "pearson_r": r,
        "img1_mean": v1.mean(),
        "img1_std": v1.std(),
        "img1_median": np.median(v1),
        "img2_mean": v2.mean(),
        "img2_std": v2.std(),
        "img2_median": np.median(v2),
    }


def print_summary(metrics: dict) -> None:
    """Pretty-print the metrics dict as aligned, rounded key: value lines."""
    label_width = max(len(key) for key in metrics)
    print("\n=== Comparison Summary ===")
    for key, value in metrics.items():
        if isinstance(value, (float, np.floating)):
            value_str = f"{value:.4f}"
        elif isinstance(value, (int, np.integer)):
            value_str = f"{value:,}"
        else:
            value_str = str(value)
        print(f"{key:>{label_width}}: {value_str}")
    print()


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
