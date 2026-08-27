#!/usr/bin/env bash
#
# run_tortoise_eddy.sh
#
# TORTOISE V4 -- eddy-current and subject motion correction ONLY. Denoising,
# Gibbs, and EPI (topup/DR-BUDDI) correction are all explicitly disabled,
# isolating exactly the "Eddy-current + motion correction" scope item.
#
# Input format: identical requirement to run_tortoise_denoise.sh /
# run_tortoise_degibbs.sh -- TORTOISEProcess --up_data takes exactly one
# NIfTI file, so this consumes output/concat/dwi_concat.nii produced by
# concatenate_inputs.sh (dwicat-merge of series 28 + 30). Run
# concatenate_inputs.sh before this script.
#
# -c / --correction_mode:
#   Per TORTOISEProcess's own --help, this flag alone controls motion &
#   eddy-currents distortion correction, independently of --epi:
#     off        no motion or eddy currents distortion correction
#     motion     corrects only motion with a rigid transformation
#     eddy_only  corrects only eddy-currents distortions and no motion
#     quadratic  motion & eddy; eddy currents modeled with up to quadratic
#                Laplace bases -- "sufficient 99% of the time" (tool default)
#     cubic      motion & eddy, with up-to-cubic Laplace bases
#   quadratic (the tool's own default) is used here, matching this repo's
#   convention of using each tool's own default settings rather than tuning
#   them (see -denoise's default box patch, -degibbs's default RPG settings).
#
# --epi off:
#   Disables EPI/susceptibility distortion correction (topup / DR-BUDDI).
#   Confirmed via TORTOISEProcess --help that -c and --epi are independent
#   flags -- motion & eddy-currents correction (-c) does not require
#   reverse phase-encoded data or --down_data/DR-BUDDI. Reverse-PE data
#   (series _38/_39_ph) is intentionally NOT used here; it is only needed
#   for EPI/susceptibility distortion correction, which is a separate,
#   explicitly out-of-scope comparison for now.
#
# --s2v 0 --repol 0:
#   Disable intra-volume (slice-to-volume) motion correction and outlier
#   replacement -- these are additional refinements layered on top of the
#   base motion+eddy correction (-c), out of scope here, same as in
#   run_tortoise_denoise.sh / run_tortoise_degibbs.sh.
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): eurotomania/tortoise:latest
#
# End-to-end: after producing (or finding an existing) dwi_eddy.nii, this
# script chains into run_tmi.sh to fit DTI/DKI parameter maps -- so a single
# invocation goes from raw input through preprocessing to parametric maps.
#
# Usage
# -----
#   ./run_tortoise_eddy.sh [output_dir]
#
# output_dir defaults to output/tortoise_eddy (relative to the repo root).
# If output_dir already contains dwi_eddy.nii (i.e. TORTOISE has already
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

# --- Resolve output directory (arg 1, default output/tortoise_eddy) --------
OUT_DIR_ARG="${1:-output/tortoise_eddy}"
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
FINAL_NII="${OUT_DIR}/dwi_eddy.nii"

if [[ -f "${FINAL_NII}" ]]; then
    echo "== run_tortoise_eddy.sh =="
    echo "Output: ${OUT_REL}/dwi_eddy.nii already exists -- skipping TORTOISE, running tmi only."
    echo
else
    if [[ ! -f "${CONCAT_NII}" ]]; then
        echo "ERROR: ${CONCAT_NII} not found." >&2
        echo "       Run ./concatenate_inputs.sh first (dwicat-merges series 28+30)." >&2
        exit 1
    fi

    mkdir -p "${OUT_DIR}"

    echo "== run_tortoise_eddy.sh =="
    echo "Image:  ${TORTOISE_IMAGE}"
    echo "Input:  output/concat/dwi_concat.nii  (dwicat-merged series 28+30)"
    echo "Step:   -c quadratic only (motion & eddy-currents; denoising/gibbs/epi disabled, no reverse-PE)"
    echo "Output: ${OUT_REL}/dwi_eddy.*"
    echo

    docker run --rm \
        --platform linux/amd64 \
        -v "${SCRIPT_DIR}:/data" \
        "${EXTRA_MOUNTS[@]}" \
        "${TORTOISE_IMAGE}" \
        TORTOISEProcess \
            --up_data /data/output/concat/dwi_concat.nii \
            --denoising off \
            --gibbs 0 \
            -c quadratic \
            --epi off \
            --s2v 0 \
            --repol 0 \
            --output /data/${OUT_REL}/dwi_eddy.nii
fi

echo "== run_tortoise_eddy.sh: running tmi =="
"${SCRIPT_DIR}/run_tmi.sh" "${FINAL_NII}"
