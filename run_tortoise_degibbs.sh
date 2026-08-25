#!/usr/bin/env bash
#
# run_tortoise_degibbs.sh
#
# TORTOISE V4 -- Gibbs-ringing removal step ONLY. Denoising, motion, eddy,
# and EPI (topup) correction are all explicitly disabled, isolating exactly
# the "Gibbs removal: TORTOISE = denoising only [step disabled here] /
# Gibbs removal only" scope item. Runs on the same dwicat-merged input as
# run_tortoise_denoise.sh (independent of that script's output), per the
# confirmed "step isolation" decision.
#
# Input format: identical requirement to run_tortoise_denoise.sh --
# TORTOISEProcess --up_data takes exactly one NIfTI file, so this consumes
# output/concat/dwi_concat.nii produced by concatenate_inputs.sh
# (dwicat-merge of series 28 + 30). Run concatenate_inputs.sh before this
# script.
#
# TORTOISE automatically decides between k-space and local subvoxel-shift
# Gibbs-correction methodology based on the partial-Fourier /  k-space
# coverage information in the input; no separate PF flag is documented for
# --gibbs (unlike DESIGNER's RPG, which requires -pf/-pe_dir explicitly).
#
# Flags:
#   --denoising off          disable denoising (separate script)
#   --gibbs 1                enable Gibbs-ringing correction (default on)
#   -c off                   disable motion/eddy-current correction (out of scope)
#   --epi off                disable EPI/susceptibility (topup) correction (out of scope)
#   --s2v 0 --repol 0         disable intra-volume motion + outlier replacement (out of scope)
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): eurotomania/tortoise:latest
#
# End-to-end: after producing (or finding an existing) dwi_degibbs.nii, this
# script chains into run_tmi.sh to fit DTI/DKI parameter maps -- so a single
# invocation goes from raw input through preprocessing to parametric maps.
# If output/tortoise_degibbs/dwi_degibbs.nii already exists (i.e. TORTOISE
# has already been run), the TORTOISE/docker step is skipped and this script
# goes straight to run_tmi.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONCAT_DIR="${SCRIPT_DIR}/output/concat"
CONCAT_NII="${CONCAT_DIR}/dwi_concat.nii"
OUT_DIR="${SCRIPT_DIR}/output/tortoise_degibbs"
FINAL_NII="${OUT_DIR}/dwi_degibbs.nii"
TORTOISE_IMAGE="eurotomania/tortoise:latest"

if [[ -f "${FINAL_NII}" ]]; then
    echo "== run_tortoise_degibbs.sh =="
    echo "Output: output/tortoise_degibbs/dwi_degibbs.nii already exists -- skipping TORTOISE, running tmi only."
    echo
else
    if [[ ! -f "${CONCAT_NII}" ]]; then
        echo "ERROR: ${CONCAT_NII} not found." >&2
        echo "       Run ./concatenate_inputs.sh first (dwicat-merges series 28+30)." >&2
        exit 1
    fi

    mkdir -p "${OUT_DIR}"

    echo "== run_tortoise_degibbs.sh =="
    echo "Image:  ${TORTOISE_IMAGE}"
    echo "Input:  output/concat/dwi_concat.nii  (dwicat-merged series 28+30)"
    echo "Step:   --gibbs 1 only (denoising/motion/eddy/epi disabled)"
    echo "Output: output/tortoise_degibbs/dwi_degibbs.*"
    echo

    docker run --rm \
        --platform linux/amd64 \
        -v "${SCRIPT_DIR}:/data" \
        "${TORTOISE_IMAGE}" \
        TORTOISEProcess \
            --up_data /data/output/concat/dwi_concat.nii \
            --denoising off \
            --gibbs 1 \
            -c off \
            --epi off \
            --s2v 0 \
            --repol 0 \
            --output /data/output/tortoise_degibbs/dwi_degibbs.nii
fi

echo "== run_tortoise_degibbs.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
