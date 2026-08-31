#!/usr/bin/env bash
#
# run_tmi.sh
#
# Fits DKI (fa, md, ad, rd, eigenvalues/eigenvectors, mk, ak, rk) and WDKI
# (mw) parameter maps on a preprocessed DWI (a DESIGNER or TORTOISE pipeline
# output) using `tmi`, NYU's DESIGNER-v2 companion fitting tool.
#
# `tmi` is bundled inside the same Docker image as `designer` (confirmed via
# `docker run --rm nyudiffusionmri/designer2:v2.0.16 tmi -h`), not installed
# on the host -- this script runs it the same dockerized way as
# run_designer_denoise.sh / run_designer_degibbs.sh.
#
# Usage (from the project root)
# -----
#   ./scripts/run_tmi.sh <path/to/dwi.nii>
#
# e.g.:
#   ./scripts/run_tmi.sh output/designer_denoise/dwi_denoised.nii
#   ./scripts/run_tmi.sh output/tortoise_degibbs/dwi_degibbs.nii
#
# Output: params/ created next to the input DWI (e.g.
# output/designer_denoise/params/), containing tmi's DKI + WDKI maps.
#
# Flags used:
#   -DKI -WDKI     tensor fitting only -- no -SMI, no -DTI (per user's
#                 request: SMI excluded entirely).
#   -mask         output/brain_mask/brain_mask.nii.gz (from
#                 extract_brain_mask.sh).
#   -fslbval/-fslbvec
#                 explicitly point at the input's gradient-table sidecars.
#                 DESIGNER writes `.bval`/`.bvec` (singular); TORTOISE
#                 writes `.bvals`/`.bvecs` (plural) -- tmi's default
#                 auto-detection isn't guaranteed to handle both, so this
#                 script detects whichever pair is present and passes it
#                 explicitly rather than relying on that auto-detection.
#   No -sigma (per user's request: not required, explicitly omitted).
#
# Docker image (pinned, same version as the other DESIGNER scripts):
# nyudiffusionmri/designer2:v2.0.16

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DESIGNER_IMAGE="nyudiffusionmri/designer2:v2.0.16"
BRAIN_MASK="${PROJECT_ROOT}/output/brain_mask/brain_mask.nii.gz"

# input/ and output/ may be symlinks to a network mount (e.g. CIFS). Docker's
# bind mount below does not follow host symlinks out of PROJECT_ROOT, so the
# container would see a dangling symlink. Mount each symlink's real target at
# the same absolute path so it resolves correctly inside the container too.
EXTRA_MOUNTS=()
for _d in input output; do
    if [[ -L "${PROJECT_ROOT}/${_d}" ]]; then
        _target="$(readlink -f "${PROJECT_ROOT}/${_d}")"
        EXTRA_MOUNTS+=(-v "${_target}:${_target}")
    fi
done

if [[ $# -ne 1 ]]; then
    echo "Usage: ./scripts/run_tmi.sh <path/to/dwi.nii>" >&2
    echo "  e.g. ./scripts/run_tmi.sh output/designer_denoise/dwi_denoised.nii" >&2
    exit 1
fi

INPUT_ARG="$1"

if [[ ! -f "${INPUT_ARG}" ]]; then
    echo "ERROR: input DWI not found: ${INPUT_ARG}" >&2
    exit 1
fi

INPUT_ABS="$(cd "$(dirname "${INPUT_ARG}")" && pwd)/$(basename "${INPUT_ARG}")"

case "${INPUT_ABS}" in
    "${PROJECT_ROOT}"/*) ;;
    *)
        echo "ERROR: ${INPUT_ABS} is outside the repo (${PROJECT_ROOT})." >&2
        echo "       Docker only mounts the repo root, so the input must live inside it." >&2
        exit 1
        ;;
esac

if [[ ! -f "${BRAIN_MASK}" ]]; then
    echo "ERROR: ${BRAIN_MASK} not found." >&2
    echo "       Run ./scripts/extract_brain_mask.sh first." >&2
    exit 1
fi

# Detect gradient-table sidecars: DESIGNER uses .bval/.bvec (singular),
# TORTOISE uses .bvals/.bvecs (plural).
INPUT_NOEXT="${INPUT_ABS%.*}"
if [[ -f "${INPUT_NOEXT}.bval" && -f "${INPUT_NOEXT}.bvec" ]]; then
    BVAL="${INPUT_NOEXT}.bval"
    BVEC="${INPUT_NOEXT}.bvec"
elif [[ -f "${INPUT_NOEXT}.bvals" && -f "${INPUT_NOEXT}.bvecs" ]]; then
    BVAL="${INPUT_NOEXT}.bvals"
    BVEC="${INPUT_NOEXT}.bvecs"
else
    echo "ERROR: no gradient-table sidecars found for ${INPUT_ABS}." >&2
    echo "       Tried ${INPUT_NOEXT}.bval/.bvec and ${INPUT_NOEXT}.bvals/.bvecs" >&2
    exit 1
fi

OUTPUT_DIR="$(dirname "${INPUT_ABS}")/params"
mkdir -p "${OUTPUT_DIR}"

# Paths as seen inside the container (repo root bind-mounted at /data).
INPUT_REL="${INPUT_ABS#"${PROJECT_ROOT}"/}"
BVAL_REL="${BVAL#"${PROJECT_ROOT}"/}"
BVEC_REL="${BVEC#"${PROJECT_ROOT}"/}"
MASK_REL="${BRAIN_MASK#"${PROJECT_ROOT}"/}"
OUTPUT_REL="${OUTPUT_DIR#"${PROJECT_ROOT}"/}"

echo "== run_tmi.sh =="
echo "Image:  ${DESIGNER_IMAGE}"
echo "Input:  ${INPUT_REL}"
echo "Mask:   ${MASK_REL}"
echo "Fit:    -DKI -WDKI (no -SMI, no -DTI, no -sigma)"
echo "Output: ${OUTPUT_REL}/"
echo

docker run --rm \
    --platform linux/amd64 \
    -v "${PROJECT_ROOT}:/data" \
    "${EXTRA_MOUNTS[@]}" \
    -w /data \
    "${DESIGNER_IMAGE}" \
    tmi \
        -DKI -WDKI \
        -fit_constraints 1,1,1 \
        -akc_outliers \
        -mask "/data/${MASK_REL}" \
        -fslbval "/data/${BVAL_REL}" \
        -fslbvec "/data/${BVEC_REL}" \
        "/data/${INPUT_REL}" \
        "/data/${OUTPUT_REL}"

echo "Wrote: ${OUTPUT_DIR}"
