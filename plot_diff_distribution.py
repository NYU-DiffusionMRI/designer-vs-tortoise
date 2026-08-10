#!/usr/bin/env python
"""
plot_diff_distribution.py

Minimal histogram of the voxel-value distribution in a difference NIfTI
image (e.g. compare_dwi.py's abs_diff.nii.gz).

Usage:
    python plot_diff_distribution.py results/<run>/abs_diff.nii.gz \
        --output results/<run>/diff_hist.png --bins 100

Excludes NaN/Inf voxels and exact-zero voxels (background) before plotting.
Default --output is <input-stem>_distribution.png next to the input file.
"""

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import nibabel as nib
import numpy as np


def parse_args():
    parser = argparse.ArgumentParser(
        description="Plot a histogram of voxel values in a difference NIfTI image."
    )
    parser.add_argument("diff_img", type=Path, help="Difference NIfTI image (e.g. abs_diff.nii.gz)")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output PNG path (default: <input-stem>_distribution.png next to the input)",
    )
    parser.add_argument("--bins", type=int, default=100, help="Number of histogram bins (default: 100)")
    return parser.parse_args()


def load_values(path: Path) -> np.ndarray:
    """Load a NIfTI image and return its finite, non-zero voxel values flattened."""
    data = np.asarray(nib.load(path).get_fdata(), dtype=np.float64).ravel()
    mask = np.isfinite(data) & (data != 0)
    return data[mask]


def plot_distribution(values: np.ndarray, bins: int, output: Path) -> None:
    mean, median = values.mean(), np.median(values)

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.hist(values, bins=bins, color="steelblue", edgecolor="none")
    ax.axvline(mean, color="firebrick", linestyle="--", label=f"mean = {mean:.4g}")
    ax.axvline(median, color="darkorange", linestyle="--", label=f"median = {median:.4g}")
    ax.set_xlabel("Difference value")
    ax.set_ylabel("Voxel count")
    ax.set_title("Distribution of difference values")
    ax.legend()
    fig.tight_layout()
    fig.savefig(output, dpi=150)
    plt.close(fig)


def main():
    args = parse_args()
    output = args.output or args.diff_img.with_name(f"{args.diff_img.stem.removesuffix('.nii')}_distribution.png")

    values = load_values(args.diff_img)
    print(
        f"n_voxels={values.size:,}  mean={values.mean():.4g}  "
        f"median={np.median(values):.4g}  std={values.std():.4g}"
    )

    plot_distribution(values, args.bins, output)
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
