Compare Designer vs Tortoise

## Scope

Current comparison covers **only**:

1. Denoising — DESIGNER v2: MP-PCA (box patch) · TORTOISE V4: denoising step only
2. Gibbs ringing removal — DESIGNER v2: RPG · TORTOISE V4: Gibbs-removal step only
3. Eddy-current + motion correction — DESIGNER v2: FSL eddy via `-eddy -rpe_none`
   (no reverse phase-encoding data) · TORTOISE V4: `-c quadratic` (motion &
   eddy-currents) with `--epi off`
4. Eddy-current + motion correction WITH susceptibility distortion correction
   (SDC), using the reverse-PE (PA) pair — DESIGNER v2: FSL eddy via
   `-eddy -rpe_pair <PA>` (GPU) · TORTOISE V4: `-c quadratic --epi DRBUDDI
   -d <PA>` (GPU, `TORTOISEProcess_cuda`)

Gradient nonlinearity correction (GNC) and all other preprocessing are
explicitly out of scope and disabled in every script below.

## Pinned Docker images

Only these image tags are used anywhere in this repo's scripts. Do not substitute
other versions without asking first.

| Pipeline | Image |
|---|---|
| DESIGNER v2 | `nyudiffusionmri/designer2:v2.0.16` |
| TORTOISE V4 | `eurotomania/tortoise:latest` |

`scripts/concatenate_inputs.sh` runs on the host's local MRtrix3 install (`dwicat`,
`mrinfo`) — concatenation is upstream of both pipelines and isn't part of either
vendor image.

## Setup

```
conda env create -f environment.yml   # also installs this repo's own
                                       # dwicompare package editable (pip -e .)
conda activate designer-vs-tortoise
```

For an already-existing env, the editable install alone is `pip install -e .`
(run from the project root). All scripts below are invoked from the project
root, e.g. `./scripts/run_tmi.sh ...` or `python scripts/compare_maps.py ...`.

## Input data (`input/`)

One study, several series from the same session. Only two are DWI series relevant
to this scope:

| Series | Description | Vols | b-value | PE dir | Role |
|---|---|---|---|---|---|
| `_9` | MPRAGE | 1 | — | — | anatomical T1 — **excluded** (not DWI) |
| `_28` | V6meso_RMR_b1_Delta63 | 21 | ~1000 | `j-` | DWI shell 1 — **used** |
| `_29_ph` | same, phase recon | 21 | 0 (placeholder) | `j-` | complex-recon phase pair — **excluded** |
| `_30` | V6meso_RMR_b2_Delta63 | 62 | ~2000 | `j-` | DWI shell 2 — **used** |
| `_31_ph` | same, phase recon | 62 | 0 (placeholder) | `j-` | complex-recon phase pair — **excluded** |
| `_38` | V6meso_RMR_PA_Delta63 | 2 | 0 | `j` | reverse-PE topup pair — **used** (SDC scripts only) |
| `_39_ph` | same, phase recon | 1 | 0 | `j` | complex-recon phase pair — **excluded** |

**`_ph` is not reverse phase-encoding.** Each `_ph` file's JSON sidecar has
`ImageType` containing `"P"`/`"PHASE"`, a `_PHASE`-suffixed `SeriesDescription`, a
`part-phase` `BidsGuess`, and identical volume count/geometry/PE-direction to its
magnitude twin — it's the scanner's complex-reconstruction phase image, paired with
each magnitude series (28↔29_ph, 30↔31_ph, 38↔39_ph). The actual reverse-PE pair is
series 28/30 (`j-`) vs. series 38 (`j`), which exists for topup/DR-BUDDI
susceptibility distortion correction (SDC), used by the `*_eddy_sdc.sh` scripts only.

Series 28 + 30 (the two DWI shells, 83 volumes combined) are the primary inputs
used by every script in this repo; series 38 (the PA reverse-PE pair) is additionally
used by `run_designer_eddy_sdc.sh` / `run_tortoise_eddy_sdc.sh` for SDC.

## Scripts

All scripts live in `scripts/` and are invoked from the project root (see
Setup above).

| Script | Tool | Step | Input |
|---|---|---|---|
| `scripts/concatenate_inputs.sh` | MRtrix3 (`dwicat`, host) | merges series 28+30 → `output/concat/dwi_concat.*` | series 28, 30 |
| `scripts/run_designer_denoise.sh` | DESIGNER v2 | `-denoise` only | `input/*_28.nii,input/*_30.nii` (native comma-list) |
| `scripts/run_designer_degibbs.sh` | DESIGNER v2 | `-degibbs` only (RPG, `-pf 0.75 -pe_dir j-`) | `input/*_28.nii,input/*_30.nii` (native comma-list) |
| `scripts/run_tortoise_denoise.sh` | TORTOISE V4 | `--denoising for_final` only | `output/concat/dwi_concat.nii` |
| `scripts/run_tortoise_degibbs.sh` | TORTOISE V4 | `--gibbs 1` only | `output/concat/dwi_concat.nii` |
| `scripts/run_designer_eddy.sh` | DESIGNER v2 | `-eddy -rpe_none -pe_dir j-` only (no reverse-PE) | `input/*_28.nii,input/*_30.nii` (native comma-list) |
| `scripts/run_tortoise_eddy.sh` | TORTOISE V4 | `-c quadratic --epi off` only | `output/concat/dwi_concat.nii` |
| `scripts/run_designer_eddy_sdc.sh` | DESIGNER v2 (GPU) | `-eddy -rpe_pair <PA> -pe_dir j-` (SDC) | `input/*_28.nii,input/*_30.nii,input/*_38.nii` |
| `scripts/run_tortoise_eddy_sdc.sh` | TORTOISE V4 (GPU, `TORTOISEProcess_cuda`) | `-c quadratic --epi DRBUDDI -d <PA>` (SDC) | `output/concat/dwi_concat.nii` + `input/*_38.nii` |

Run `scripts/concatenate_inputs.sh` before any `run_tortoise_*.sh` script — TORTOISE's
`--up_data` accepts exactly one NIfTI file, unlike DESIGNER's native
comma-separated multi-series input, so the two shells must be pre-merged for
TORTOISE only. See the header comment in each script for the full reasoning.

**Design choices confirmed with the user:**
- DESIGNER consumes the two original per-shell files directly (its own documented
  multi-series mechanism) rather than the `dwicat`-harmonized file, so TORTOISE's
  intensity-scaling correction doesn't leak into the DESIGNER arm.
- The denoise-only and degibbs-only scripts per tool each start independently from
  the same input (not chained), so each algorithm is isolated for comparison.
- Phase (`_ph`) series are excluded from this comparison entirely. The reverse-PE
  pair (`_38`) is used, but only by the `*_eddy_sdc.sh` scripts, for SDC.
- `run_designer_eddy.sh` / `run_tortoise_eddy.sh` intentionally do not use
  reverse-PE data: eddy-current/motion correction and EPI/susceptibility
  (topup) correction are independent steps in both tools — confirmed directly
  against each pinned image's own `--help` output. DESIGNER's `-rpe_none`
  performs "eddy current and motion correction only" with no reverse-PE
  input; TORTOISE's `-c` (motion & eddy-currents) and `--epi` (susceptibility
  correction) are separate flags with no dependency between them.
- `run_designer_eddy_sdc.sh` / `run_tortoise_eddy_sdc.sh` add SDC using the
  reverse-PE pair (series `_38`), with GPU for both tools (`--gpus all`, and
  `TORTOISEProcess_cuda` for TORTOISE, which — unlike FSL `eddy` — does not
  auto-detect GPU and requires the CUDA-suffixed binary explicitly). The
  structural (MPRAGE) image is intentionally not passed to TORTOISE's DR-BUDDI
  (`-s/--structural`), to keep parity with every other script's DWI-only input
  convention. DESIGNER's `-rpe_pair` internally chains FSL `topup`'s output
  into FSL `eddy` (`--topup=<prefix>`) within one `designer` call, matching
  FSL's own topup→eddy workflow; TORTOISE's own fixed pipeline order instead
  runs motion+eddy correction *before* DR-BUDDI SDC — an intentional, accepted
  difference in each tool's native architecture, not a bug (see the header
  comment in `run_tortoise_eddy_sdc.sh` for the full reasoning).

None of these scripts have been executed — review the commands against your own
DESIGNER/TORTOISE install before running them.
