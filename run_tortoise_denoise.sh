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
#
# End-to-end: after producing (or finding an existing) dwi_denoised.nii, this
# script chains into run_tmi.sh to fit DTI/DKI parameter maps -- so a single
# invocation goes from raw input through preprocessing to parametric maps.
#
# Usage
# -----
#   ./run_tortoise_denoise.sh [output_dir]
#
# output_dir defaults to output/tortoise_denoise (relative to the repo root).
# If output_dir already contains dwi_denoised.nii (i.e. TORTOISE has already
# been run there), the TORTOISE/docker step is skipped and this script goes
# straight to run_tmi.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# input/ and output/ may be symlinks to a network mount (e.g. CIFS). Docker's
# bind mount below does not follow host symlinks out of SCRIPT_DIR, so the
# container would see a dangling symlink. Mount each symlink's real target at
# the same absolute path so it resolves correctly inside the container too.
EXTRA_MOUNTS=()
for _d in input output; do
    if [[ -L "${SCRIPT_DIR}/${_d}" ]]; then
        _target="$(readlink -f "${SCRIPT_DIR}/${_d}")"
        EXTRA_MOUNTS+=(-v "${_target}:${_target}")
    fi
done

CONCAT_DIR="${SCRIPT_DIR}/output/concat"
CONCAT_NII="${CONCAT_DIR}/dwi_concat.nii"
TORTOISE_IMAGE="eurotomania/tortoise:latest"

# --- Resolve output directory (arg 1, default output/tortoise_denoise) -----
OUT_DIR_ARG="${1:-output/tortoise_denoise}"
case "${OUT_DIR_ARG}" in
    /*) OUT_DIR="${OUT_DIR_ARG}" ;;
    *)  OUT_DIR="${SCRIPT_DIR}/${OUT_DIR_ARG}" ;;
esac

case "${OUT_DIR}" in
    "${SCRIPT_DIR}"/*) ;;
    *)
        echo "ERROR: output dir ${OUT_DIR} is outside the repo (${SCRIPT_DIR})." >&2
        echo "       Docker only mounts the repo root, so the output dir must live inside it." >&2
        exit 1
        ;;
esac

OUT_REL="${OUT_DIR#"${SCRIPT_DIR}"/}"
FINAL_NII="${OUT_DIR}/dwi_denoised.nii"

if [[ -f "${FINAL_NII}" ]]; then
    echo "== run_tortoise_denoise.sh =="
    echo "Output: ${OUT_REL}/dwi_denoised.nii already exists -- skipping TORTOISE, running tmi only."
    echo
else
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
    echo "Output: ${OUT_REL}/dwi_denoised.*"
    echo

    docker run --rm \
        --platform linux/amd64 \
        -v "${SCRIPT_DIR}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        "${TORTOISE_IMAGE}" \
        TORTOISEProcess \
            --up_data /data/output/concat/dwi_concat.nii \
            --denoising for_final \
            --gibbs 0 \
            -c off \
            --epi off \
            --s2v 0 \
            --repol 0 \
            --output /data/${OUT_REL}/dwi_denoised.nii
fi

echo "== run_tortoise_denoise.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
