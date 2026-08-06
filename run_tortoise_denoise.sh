#!/usr/bin/env bash
#
# run_tortoise_denoise.sh
#
# TORTOISE V4 -- denoising step ONLY. Gibbs, motion, eddy, and EPI
# (topup) correction are all explicitly disabled, isolating exactly the
# "Denoising: TORTOISE = denoising only" scope item.
#
# Input format (per TORTOISEV4 README,
# https://github.com/QMICodeBase/TORTOISEV4): TORTOISEProcess --up_data
# takes exactly ONE NIfTI file (with matching .bval/.bvec/.json sidecars by
# basename). Because our acquisition has two separate DWI shells (series 28
# + 30), they MUST be pre-merged -- see concatenate_inputs.sh, which uses
# MRtrix3's `dwicat` (the intensity-scaling-aware DWI concatenation tool,
# not raw mrcat) to produce output/concat/dwi_concat.nii. Run
# concatenate_inputs.sh before this script.
#
# Flags:
#   --denoising for_final   enable TORTOISE's denoising step
#   --gibbs 0                disable Gibbs-ringing correction (separate script)
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
OUT_DIR="${SCRIPT_DIR}/output/tortoise_denoise"
TORTOISE_IMAGE="eurotomania/tortoise:latest"

if [[ ! -f "${CONCAT_NII}" ]]; then
    echo "ERROR: ${CONCAT_NII} not found." >&2
    echo "       Run ./concatenate_inputs.sh first (dwicat-merges series 28+30)." >&2
    exit 1
fi

mkdir -p "${OUT_DIR}"

echo "== run_tortoise_denoise.sh =="
echo "Image:  ${TORTOISE_IMAGE}"
echo "Input:  output/concat/dwi_concat.nii  (dwicat-merged series 28+30)"
echo "Step:   --denoising for_final only (gibbs/motion/eddy/epi disabled)"
echo "Output: output/tortoise_denoise/dwi_denoised.*"
echo

docker run --rm \
    -v "${SCRIPT_DIR}:/data" \
    "${TORTOISE_IMAGE}" \
    TORTOISEProcess \
        --up_data /data/output/concat/dwi_concat.nii \
        --denoising for_final \
        --gibbs 0 \
        -c off \
        --epi off \
        --s2v 0 \
        --repol 0 \
        --output /data/output/tortoise_denoise/dwi_denoised.nii
