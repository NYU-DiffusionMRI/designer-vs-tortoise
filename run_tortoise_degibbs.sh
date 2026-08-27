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
#
# Usage
# -----
#   ./run_tortoise_degibbs.sh [output_dir]
#
# output_dir defaults to output/tortoise_degibbs (relative to the repo root).
# If output_dir already contains dwi_degibbs.nii (i.e. TORTOISE has already
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

# --- Resolve output directory (arg 1, default output/tortoise_degibbs) -----
OUT_DIR_ARG="${1:-output/tortoise_degibbs}"
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
FINAL_NII="${OUT_DIR}/dwi_degibbs.nii"

if [[ -f "${FINAL_NII}" ]]; then
    echo "== run_tortoise_degibbs.sh =="
    echo "Output: ${OUT_REL}/dwi_degibbs.nii already exists -- skipping TORTOISE, running tmi only."
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
    echo "Output: ${OUT_REL}/dwi_degibbs.*"
    echo

    docker run --rm \
        --platform linux/amd64 \
        -v "${SCRIPT_DIR}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        "${TORTOISE_IMAGE}" \
        TORTOISEProcess \
            --up_data /data/output/concat/dwi_concat.nii \
            --denoising off \
            --gibbs 1 \
            -c off \
            --epi off \
            --s2v 0 \
            --repol 0 \
            --output /data/${OUT_REL}/dwi_degibbs.nii
fi

echo "== run_tortoise_degibbs.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
