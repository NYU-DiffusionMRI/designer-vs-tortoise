Compare Designer vs Tortoise

## Scope

Current comparison covers **only**:

1. Denoising — DESIGNER v2: MP-PCA (box patch) · TORTOISE V4: denoising step only
2. Gibbs ringing removal — DESIGNER v2: RPG · TORTOISE V4: Gibbs-removal step only

Eddy, topup, motion correction, gradient nonlinearity correction (GNC), and all
other preprocessing are explicitly out of scope and disabled in every script below.

## Pinned Docker images

Only these image tags are used anywhere in this repo's scripts. Do not substitute
other versions without asking first.

| Pipeline | Image |
|---|---|
| DESIGNER v2 | `nyudiffusionmri/designer2:v2.0.16` |
| TORTOISE V4 | `eurotomania/tortoise:latest` |

`concatenate_inputs.sh` runs on the host's local MRtrix3 install (`dwicat`,
`mrinfo`) — concatenation is upstream of both pipelines and isn't part of either
vendor image.

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
| `_38` | V6meso_RMR_PA_Delta63 | 2 | 0 | `j` | reverse-PE topup pair — **excluded** (out of scope) |
| `_39_ph` | same, phase recon | 1 | 0 | `j` | complex-recon phase pair — **excluded** |

**`_ph` is not reverse phase-encoding.** Each `_ph` file's JSON sidecar has
`ImageType` containing `"P"`/`"PHASE"`, a `_PHASE`-suffixed `SeriesDescription`, a
`part-phase` `BidsGuess`, and identical volume count/geometry/PE-direction to its
magnitude twin — it's the scanner's complex-reconstruction phase image, paired with
each magnitude series (28↔29_ph, 30↔31_ph, 38↔39_ph). The actual reverse-PE pair is
series 28/30 (`j-`) vs. series 38 (`j`), which exists for topup/eddy susceptibility
correction and is out of scope here.

Series 28 + 30 (the two DWI shells, 83 volumes combined) are the only inputs used
by the scripts in this repo.

## Scripts

| Script | Tool | Step | Input |
|---|---|---|---|
| `concatenate_inputs.sh` | MRtrix3 (`dwicat`, host) | merges series 28+30 → `output/concat/dwi_concat.*` | series 28, 30 |
| `run_designer_denoise.sh` | DESIGNER v2 | `-denoise` only | `input/*_28.nii,input/*_30.nii` (native comma-list) |
| `run_designer_degibbs.sh` | DESIGNER v2 | `-degibbs` only (RPG, `-pf 0.75 -pe_dir j-`) | `input/*_28.nii,input/*_30.nii` (native comma-list) |
| `run_tortoise_denoise.sh` | TORTOISE V4 | `--denoising for_final` only | `output/concat/dwi_concat.nii` |
| `run_tortoise_degibbs.sh` | TORTOISE V4 | `--gibbs 1` only | `output/concat/dwi_concat.nii` |

Run `concatenate_inputs.sh` before either `run_tortoise_*.sh` script — TORTOISE's
`--up_data` accepts exactly one NIfTI file, unlike DESIGNER's native
comma-separated multi-series input, so the two shells must be pre-merged for
TORTOISE only. See the header comment in each script for the full reasoning.

**Design choices confirmed with the user:**
- DESIGNER consumes the two original per-shell files directly (its own documented
  multi-series mechanism) rather than the `dwicat`-harmonized file, so TORTOISE's
  intensity-scaling correction doesn't leak into the DESIGNER arm.
- The denoise-only and degibbs-only scripts per tool each start independently from
  the same input (not chained), so each algorithm is isolated for comparison.
- Phase (`_ph`) series and the reverse-PE pair (`_38`/`_39_ph`) are excluded from
  this comparison entirely.

None of these scripts have been executed — review the commands against your own
DESIGNER/TORTOISE install before running them.
