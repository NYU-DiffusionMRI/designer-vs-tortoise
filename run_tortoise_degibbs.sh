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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONCAT_DIR="${SCRIPT_DIR}/output/concat"
CONCAT_NII="${CONCAT_DIR}/dwi_concat.nii"
OUT_DIR="${SCRIPT_DIR}/output/tortoise_degibbs"
TORTOISE_IMAGE="eurotomania/tortoise:latest"

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
