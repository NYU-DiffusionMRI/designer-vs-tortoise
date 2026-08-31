# Compare Designer vs Tortoise

Compares two DWI preprocessing pipelines — **DESIGNER v2** and **TORTOISE V4** —
stage by stage, on the same acquisition. Each stage runs through its tool's
pinned Docker image, gets fit to DKI/WDKI parameter maps with `tmi`, and the
two tools' outputs are compared voxel-wise and ROI-wise.

## Scope

1. Denoising — DESIGNER: MP-PCA · TORTOISE: `--denoising for_final`
2. Gibbs ringing removal — DESIGNER: RPG (`-degibbs -pf 0.75`) · TORTOISE: `--gibbs 1`
3. Eddy-current + motion correction (no SDC) — DESIGNER: `-eddy -rpe_none` (GPU) · TORTOISE: `-c quadratic --epi off`
4. Eddy + motion + susceptibility distortion correction (SDC), using the reverse-PE (PA) pair — DESIGNER: `-eddy -rpe_pair <PA>` (GPU) · TORTOISE: `-c quadratic --epi DRBUDDI` (GPU, `TORTOISEProcess_cuda`)
5. Full pipeline (1–4 combined, one call per tool)

## Requirements

Pinned Docker images:

| Pipeline | Image |
|---|---|
| DESIGNER v2 | `nyudiffusionmri/designer2:v2.0.16` |
| TORTOISE V4 | `eurotomania/tortoise:latest` |

Host tools (not containerized):
- **MRtrix3** (`dwicat`, `mrconvert`) — for `concatenate_inputs.sh`
- **FSL** (`bet`, `fslmaths`, `fslselectvols`, `$FSLDIR`) — for `extract_brain_mask.sh`
- **FreeSurfer** (`module load freesurfer` → `$FREESURFER_HOME`) — only for `roi_outliers.py`'s ROI-name lookup

A GPU is required for the `_eddy_sdc` and `_full` scripts (`--gpus all`); the
other scripts run on CPU.

## Setup

```
conda env create -f environment.yml   # also pip-installs this repo's own
                                       # dwicompare package editable (-e .)
conda activate designer-vs-tortoise
```

For an already-existing env, the editable install alone is `pip install -e .`.
All commands below are run from the project root.

## Input data (`input/`)

One study, one session. Only these series matter:

| Series | Description | Vols | b-value | PE dir | Role |
|---|---|---|---|---|---|
| `_28` | b1, Delta63 | 21 | ~1000 | `j-` | DWI shell 1 — used |
| `_30` | b2, Delta63 | 62 | ~2000 | `j-` | DWI shell 2 — used |
| `_38` | PA, Delta63 | 2 | 0 | `j` | reverse-PE pair — used by `*_eddy_sdc`/`*_full` only |
| `_9`, `_29_ph`, `_31_ph`, `_39_ph` | MPRAGE / phase-recon pairs | — | — | — | excluded (not DWI / not reverse-PE) |

Series 28 + 30 are read directly by every DESIGNER script and (after
concatenation) every TORTOISE script; series 38 is additionally used for SDC.

## Pipeline

1. `./scripts/concatenate_inputs.sh` — required once, before any TORTOISE script (DESIGNER reads series 28/30 directly and doesn't need it)
2. `./scripts/extract_brain_mask.sh` — required once, before `run_tmi.sh` or the compare scripts
3. Run whichever `run_designer_*.sh` / `run_tortoise_*.sh` stage scripts you want to compare — each produces `dwi_<stage>.nii` and automatically chains into `run_tmi.sh` to fit DKI/WDKI maps into a `params/` subdirectory. Re-running is idempotent: if the output DWI already exists, the preprocessing step is skipped and only `tmi` reruns.
4. Compare a DESIGNER/TORTOISE pair for the same stage with one of the `compare_*.py` scripts.

### Scripts

| Script | What it does | Example |
|---|---|---|
| `scripts/concatenate_inputs.sh` | Host MRtrix3 `dwicat`-merges series 28+30 into `output/concat/dwi_concat.*` (TORTOISE only; no args) | `./scripts/concatenate_inputs.sh` |
| `scripts/extract_brain_mask.sh` | Host FSL: mean b0 (bval ≤ 50) → `bet -f 0.2` → `output/brain_mask/brain_mask.nii.gz` (no args) | `./scripts/extract_brain_mask.sh` |
| `scripts/run_designer_denoise.sh` | DESIGNER `-denoise` (MP-PCA) only, then `run_tmi.sh` | `./scripts/run_designer_denoise.sh [output_dir]` (default `output/designer_denoise`) |
| `scripts/run_designer_degibbs.sh` | DESIGNER `-degibbs -pf 0.75 -pe_dir j-` only | `./scripts/run_designer_degibbs.sh` |
| `scripts/run_designer_eddy.sh` | DESIGNER `-eddy -rpe_none -pe_dir j-` only (no SDC) | `./scripts/run_designer_eddy.sh` |
| `scripts/run_designer_eddy_sdc.sh` | DESIGNER `-eddy -rpe_pair <PA> -pe_dir j-` (GPU, SDC) | `./scripts/run_designer_eddy_sdc.sh` |
| `scripts/run_designer_full.sh` | DESIGNER `-denoise -degibbs -eddy -rpe_pair <PA>`, one call (GPU) | `./scripts/run_designer_full.sh` |
| `scripts/run_tortoise_denoise.sh` | TORTOISE `--denoising for_final` only (needs `dwi_concat.nii`) | `./scripts/run_tortoise_denoise.sh` |
| `scripts/run_tortoise_degibbs.sh` | TORTOISE `--gibbs 1` only | `./scripts/run_tortoise_degibbs.sh` |
| `scripts/run_tortoise_eddy.sh` | TORTOISE `-c quadratic --epi off` only (no SDC) | `./scripts/run_tortoise_eddy.sh` |
| `scripts/run_tortoise_eddy_sdc.sh` | TORTOISE `-c quadratic --epi DRBUDDI --down_data <PA>` (GPU, `TORTOISEProcess_cuda`) | `./scripts/run_tortoise_eddy_sdc.sh` |
| `scripts/run_tortoise_full.sh` | TORTOISE `--denoising for_final --gibbs 1 -c quadratic --epi DRBUDDI`, one call (GPU) | `./scripts/run_tortoise_full.sh` |
| `scripts/run_tmi.sh` | Fits DKI/WDKI maps (`-DKI -WDKI`) on any preprocessed DWI, using the brain mask | `./scripts/run_tmi.sh output/designer_denoise/dwi_denoised.nii` |
| `scripts/compare_dwi_volumes.py` | Compares 4 individual mean-b0-normalized DWI volumes between two 4D images, inside the brain mask | `python scripts/compare_dwi_volumes.py designer.nii.gz tortoise.nii.gz --volumes 3 7 25 60 --label "denoising volumes"` |
| `scripts/compare_maps.py` | Voxel-wise absolute + relative diff of FA/MD/MW between two `tmi` `params/` dirs | `python scripts/compare_maps.py output/designer_denoise/params output/tortoise_denoise/params --label "denoising maps"` |
| `scripts/compare_maps_roi.py` | Per-ROI mean FA/MD/MW scatter + Lin's CCC, using a segmentation volume (default `output/samseg/seg2dwi.nii.gz` — **not generated by any script here**, must be supplied externally) | `python scripts/compare_maps_roi.py output/designer_denoise/params output/tortoise_denoise/params --label "ROI means"` |
| `scripts/roi_outliers.py` | Flags ROIs from a `compare_maps_roi.py` CSV where designer/tortoise means differ by ≥ threshold %, with FreeSurfer ROI names | `module load freesurfer && python scripts/roi_outliers.py results/.../roi_means.csv --threshold 10.0 --output results/roi_outliers.csv` |

All `compare_*.py` scripts write into a timestamped subfolder of `results/`
(override with `--output-dir`); see each script's docstring for the full
argument list.
