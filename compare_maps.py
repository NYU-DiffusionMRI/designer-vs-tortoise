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

Two diffs are computed per map, designer treated as ground truth:
    absolute difference: |designer - tortoise|
    relative difference:  |designer - tortoise| / designer * 100   (percent)

Relative difference is undefined (and numerically unstable) where designer
is at or near zero; voxels with abs(designer) <= --rel-eps are excluded from
the relative-diff histogram/metrics and written as NaN in
relative_diff_<MAP>.nii.gz. This matters most for MW (mean kurtosis): the
whole-brain mask is not tissue-segmented, so CSF/ventricle/edge voxels where
designer's kurtosis is essentially float noise around zero can otherwise
turn a tiny absolute difference into a relative diff of many orders of
magnitude, blowing up the mean while leaving the median untouched.

--abs-range sets the x-axis / histogram range shared by all three
*absolute*-difference panels (default: 0-0.1). --rel-range sets the x-axis /
histogram range shared by all three *relative*-difference panels (default:
0-100, since it's a percentage). --rel-eps sets the near-zero-designer
exclusion threshold for the relative-diff calc (default: 1e-6). All three
are shared across FA/MD/MW rather than per-map.

Each run writes into its own timestamped subfolder of --output-dir (so repeat
runs never clobber each other):
    <output-dir>/<timestamp>[_<slugified-label>]/summary_metrics.csv
    <output-dir>/<timestamp>[_<slugified-label>]/abs_diff_<MAP>.nii.gz
    <output-dir>/<timestamp>[_<slugified-label>]/relative_diff_<MAP>.nii.gz
    <output-dir>/<timestamp>[_<slugified-label>]/map_diff_distribution.png

summary_metrics.csv has one row per map (FA, MD, MW): label, timestamp, map,
designer_img, tortoise_img, then MAD, RMSE, max abs diff, Pearson r, and
per-image mean/std/median for the absolute diff (all computed within the
brain mask), plus mean/median/max and voxel count for the relative diff
(computed within the brain mask, excluding voxels where designer == 0).
abs_diff_<MAP>.nii.gz: voxel-wise |designer - tortoise| for that map (full
volume, not restricted to the mask).
relative_diff_<MAP>.nii.gz: voxel-wise |designer - tortoise| / designer * 100
for that map (full volume, not restricted to the mask; NaN where
abs(designer) <= --rel-eps).
map_diff_distribution.png: 2x3 grid -- rows absolute diff and relative diff,
columns FA/MD/MW -- each histogram computed over the masked voxels (relative
diff additionally excludes designer == 0 voxels), with its own x-axis range.
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

DEFAULT_ABS_RANGE = (0.0, 0.1)
DEFAULT_REL_RANGE = (0.0, 100.0)
DEFAULT_REL_EPS = 1e-6


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
        "--abs-range",
        type=float,
        nargs=2,
        default=DEFAULT_ABS_RANGE,
        metavar=("MIN", "MAX"),
        help="Histogram/x-axis range shared by all three absolute-diff (FA/MD/MW) panels (default: 0.0 0.1)",
    )
    parser.add_argument(
        "--rel-range",
        type=float,
        nargs=2,
        default=DEFAULT_REL_RANGE,
        metavar=("MIN", "MAX"),
        help="Histogram/x-axis range for all three relative-diff (%%) panels (default: 0.0 100.0)",
    )
    parser.add_argument(
        "--rel-eps",
        type=float,
        default=DEFAULT_REL_EPS,
        metavar="EPS",
        help="Exclude voxels with abs(designer) <= EPS from the relative-diff calc, since a "
        "near-zero designer denominator blows up |diff|/designer*100 regardless of how small "
        "the absolute difference is (default: 1e-6)",
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
    abs_range = tuple(args.abs_range)
    rel_range = tuple(args.rel_range)

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir_name = timestamp if not args.label else f"{timestamp}_{slugify(args.label)}"
    run_dir = args.output_dir / run_dir_name
    run_dir.mkdir(parents=True)
    print(f"Run directory: {run_dir}")

    brain_mask = None
    rows = []
    fig, axes = plt.subplots(2, 3, figsize=(15, 10))
    for col_idx, (map_name, filename) in enumerate(MAP_FILENAMES.items()):
        ax_abs, ax_rel = axes[0, col_idx], axes[1, col_idx]

        designer_img = resolve_map_path(args.designer_params_dir, filename)
        tortoise_img = resolve_map_path(args.tortoise_params_dir, filename)

        nii1, nii2, data1, data2 = load_and_validate(designer_img, tortoise_img)
        if brain_mask is None:
            brain_mask = load_spatial_reference(args.mask, data1.shape) > 0
        mask = build_mask(data1, data2) & brain_mask
        # designer (data1) is treated as ground truth in the denominator; relative
        # diff is undefined (and numerically unstable) where designer is at or near
        # zero, so exclude those voxels here.
        rel_mask = mask & (np.abs(data1) > args.rel_eps)

        metrics = compute_metrics(data1, data2, mask, label=map_name)
        rel_vals = np.abs(data1 - data2)[rel_mask] / data1[rel_mask] * 100
        metrics.update(
            {
                "rel_diff_n_voxels": int(rel_mask.sum()),
                "rel_diff_mean_pct": rel_vals.mean() if rel_vals.size else float("nan"),
                "rel_diff_median_pct": np.median(rel_vals) if rel_vals.size else float("nan"),
                "rel_diff_max_pct": rel_vals.max() if rel_vals.size else float("nan"),
            }
        )
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

        abs_diff_full = np.abs(data1 - data2)
        abs_diff_path = run_dir / f"abs_diff_{map_name}.nii.gz"
        nib.save(nib.Nifti1Image(abs_diff_full, nii1.affine, nii1.header), abs_diff_path)
        print(f"Wrote {abs_diff_path}")

        rel_diff_full = np.full(data1.shape, np.nan, dtype=np.float64)
        denom_ok = np.abs(data1) > args.rel_eps
        rel_diff_full[denom_ok] = (
            np.abs(data1[denom_ok] - data2[denom_ok]) / data1[denom_ok] * 100
        )
        rel_diff_path = run_dir / f"relative_diff_{map_name}.nii.gz"
        nib.save(nib.Nifti1Image(rel_diff_full, nii1.affine, nii1.header), rel_diff_path)
        print(f"Wrote {rel_diff_path}")

        abs_diff = abs_diff_full[mask]
        ax_abs.hist(abs_diff, bins=args.bins, range=abs_range, color="steelblue", edgecolor="none")
        ax_abs.axvline(abs_diff.mean(), color="firebrick", linestyle="--", label=f"mean = {abs_diff.mean():.4g}")
        ax_abs.axvline(
            np.median(abs_diff), color="darkorange", linestyle="--", label=f"median = {np.median(abs_diff):.4g}"
        )
        ax_abs.set_xlim(abs_range)
        ax_abs.set_xlabel("|designer - tortoise|")
        ax_abs.set_ylabel("Voxel count")
        ax_abs.set_title(f"{map_name}: absolute difference")
        ax_abs.legend()

        ax_rel.hist(rel_vals, bins=args.bins, range=rel_range, color="seagreen", edgecolor="none")
        if rel_vals.size:
            ax_rel.axvline(rel_vals.mean(), color="firebrick", linestyle="--", label=f"mean = {rel_vals.mean():.4g}")
            ax_rel.axvline(
                np.median(rel_vals), color="darkorange", linestyle="--", label=f"median = {np.median(rel_vals):.4g}"
            )
        ax_rel.set_xlim(rel_range)
        ax_rel.set_xlabel("|designer - tortoise| / designer * 100 (%)")
        ax_rel.set_ylabel("Voxel count")
        ax_rel.set_title(f"{map_name}: relative difference")
        ax_rel.legend()

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
