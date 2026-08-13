#!/usr/bin/env python
"""
compare_dwi_volumes.py

Minimal comparison of a handful of individual DWI volumes between a DESIGNER
output and a TORTOISE output (e.g. denoising-only or Gibbs-removal-only), both
normalized by the same common mean-b0 and restricted to the same common BET
brain mask. No resampling is performed -- both 4D images, the mean-b0, and the
mask must already share the same shape/affine.

    normalized = DWI / mean_b0
    diff       = abs(normalized_designer - normalized_tortoise), inside mask

Usage:
    python compare_dwi_volumes.py designer_output.nii.gz tortoise_output.nii.gz \
        --volumes 3 7 25 60 \
        --output-dir results/ --label "DESIGNER vs TORTOISE - denoising volumes"

--mean-b0 and --mask default to the common files produced by
extract_brain_mask.sh (output/brain_mask/mean_b0.nii.gz and brain_mask.nii.gz).
--bval and --bvec default to img1's own sidecar (same stem, .bval/.bvec).

Each run also saves the full normalized 4D volumes next to their inputs
(<img>_normalized.nii.gz, same directory as img1/img2 -- overwritten on
each run since normalization only depends on img1/img2/mean-b0), and writes
into its own timestamped subfolder of --output-dir:
    <output-dir>/<timestamp>[_<slugified-label>]/summary_metrics.csv
    <output-dir>/<timestamp>[_<slugified-label>]/dwi_volume_diff_distribution.png

summary_metrics.csv: one row per selected volume (index, bval, bvec, then MAD,
RMSE, max abs diff, Pearson r, and per-image mean/std/median of the masked,
normalized values).
dwi_volume_diff_distribution.png: 2x2 grid, one histogram of masked
abs(diff) per volume, each labeled with volume index/b-value/bvec.
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

from compare_common import compute_metrics, load_and_validate, load_spatial_reference, print_summary, slugify


def parse_args():
    parser = argparse.ArgumentParser(
        description="Compare individual mean-b0-normalized DWI volumes inside the common brain mask."
    )
    parser.add_argument("img1", type=Path, help="First 4D DWI NIfTI (e.g. DESIGNER output)")
    parser.add_argument("img2", type=Path, help="Second 4D DWI NIfTI (e.g. TORTOISE output)")
    parser.add_argument(
        "--volumes",
        type=int,
        nargs=4,
        required=True,
        metavar=("IDX1", "IDX2", "IDX3", "IDX4"),
        help="4 volume indices to compare, manually chosen (e.g. 2 from b~1000, 2 from b~2000).",
    )
    parser.add_argument(
        "--mean-b0",
        type=Path,
        default=Path("output/brain_mask/mean_b0.nii.gz"),
        help="Common mean-b0 NIfTI used to normalize both images (default: output/brain_mask/mean_b0.nii.gz)",
    )
    parser.add_argument(
        "--mask",
        type=Path,
        default=Path("output/brain_mask/brain_mask.nii.gz"),
        help="Common BET brain mask NIfTI (default: output/brain_mask/brain_mask.nii.gz)",
    )
    parser.add_argument(
        "--bval",
        type=Path,
        default=None,
        help="bval sidecar for labeling (default: img1's own sidecar, same stem, .bval)",
    )
    parser.add_argument(
        "--bvec",
        type=Path,
        default=None,
        help="bvec sidecar for labeling (default: img1's own sidecar, same stem, .bvec)",
    )
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
        help="Short description of the comparison, e.g. 'DESIGNER vs TORTOISE - denoising volumes'. "
        "Included in the run directory name and the summary CSV.",
    )
    parser.add_argument("--bins", type=int, default=100, help="Number of histogram bins (default: 100)")
    return parser.parse_args()


def main():
    args = parse_args()
    bval_path = args.bval or args.img1.with_suffix(".bval")
    bvec_path = args.bvec or args.img1.with_suffix(".bvec")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir_name = timestamp if not args.label else f"{timestamp}_{slugify(args.label)}"
    run_dir = args.output_dir / run_dir_name
    run_dir.mkdir(parents=True)
    print(f"Run directory: {run_dir}")

    nii1, nii2, data1, data2 = load_and_validate(args.img1, args.img2)
    spatial_shape = data1.shape[:3]
    mean_b0 = load_spatial_reference(args.mean_b0, spatial_shape)
    mask = load_spatial_reference(args.mask, spatial_shape) > 0

    bvals = np.loadtxt(bval_path)
    bvecs = np.loadtxt(bvec_path)

    with np.errstate(divide="ignore", invalid="ignore"):
        normalized1 = data1 / mean_b0[..., np.newaxis]
        normalized2 = data2 / mean_b0[..., np.newaxis]

    for img_path, nii, normalized in ((args.img1, nii1, normalized1), (args.img2, nii2, normalized2)):
        normalized_path = img_path.with_name(f"{img_path.stem}_normalized.nii.gz")
        nib.save(nib.Nifti1Image(normalized.astype(np.float32), nii.affine, nii.header), normalized_path)
        print(f"Wrote {normalized_path}")

    fig, axes = plt.subplots(2, 2, figsize=(11, 8))
    rows = []
    for idx, ax in zip(args.volumes, axes.ravel()):
        vol1 = normalized1[..., idx]
        vol2 = normalized2[..., idx]
        vol_mask = mask & np.isfinite(vol1) & np.isfinite(vol2)

        metrics = compute_metrics(vol1, vol2, vol_mask, label=f"volume_{idx}")
        bval, bvec = bvals[idx], bvecs[:, idx]
        metrics = {
            "label": args.label,
            "timestamp": timestamp,
            "volume": idx,
            "bval": bval,
            "bvec_x": bvec[0],
            "bvec_y": bvec[1],
            "bvec_z": bvec[2],
            **metrics,
        }
        print_summary(metrics)
        rows.append(metrics)

        abs_diff = np.abs(vol1[vol_mask] - vol2[vol_mask])
        ax.hist(abs_diff, bins=args.bins, range=(0, 0.1), color="steelblue", edgecolor="none")
        ax.axvline(abs_diff.mean(), color="firebrick", linestyle="--", label=f"mean = {abs_diff.mean():.4g}")
        ax.set_xlim(0, 0.1)
        ax.set_xlabel("|normalized DESIGNER - normalized TORTOISE|")
        ax.set_ylabel("Voxel count")
        ax.set_title(f"vol {idx} | b≈{bval:.0f} | bvec=({bvec[0]:.2f}, {bvec[1]:.2f}, {bvec[2]:.2f})")
        ax.legend()

    fig.suptitle(args.label or "DESIGNER vs TORTOISE - normalized volume diffs")
    fig.tight_layout()
    plot_path = run_dir / "dwi_volume_diff_distribution.png"
    fig.savefig(plot_path, dpi=150)
    plt.close(fig)

    df = pd.DataFrame(rows)
    csv_path = run_dir / "summary_metrics.csv"
    df.to_csv(csv_path, index=False)

    print(f"Wrote {plot_path}")
    print(f"Wrote {csv_path}")


if __name__ == "__main__":
    main()
