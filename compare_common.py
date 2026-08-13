#!/usr/bin/env python
"""
compare_common.py

Shared voxel-wise comparison helpers used by compare_dwi.py and
compare_maps.py: load+validate a pair of NIfTI images, build a comparison
mask, compute summary metrics, and pretty-print them.
"""

import re

import nibabel as nib
import numpy as np
from pathlib import Path
from scipy.stats import pearsonr


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


def load_spatial_reference(path: Path, expected_shape: tuple) -> np.ndarray:
    """Load a 3D NIfTI (e.g. mean-b0 or brain mask) and check it matches expected_shape."""
    nii = nib.load(path)
    if nii.shape != expected_shape:
        raise ValueError(
            f"Shape mismatch: {path.name} has shape {nii.shape}, expected {expected_shape}. "
            "This script does not resample."
        )
    return np.asarray(nii.get_fdata(), dtype=np.float64)


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
