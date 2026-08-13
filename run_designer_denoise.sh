#!/usr/bin/env bash
#
# run_designer_denoise.sh
#
# DESIGNER v2 -- denoising step ONLY (MP-PCA, "box patch" / default extent).
# No -degibbs, no -eddy, no -rpe_*, no -normalize, no -b1correct: this
# isolates exactly the "Denoising: DESIGNER = MPPCA (box patch)" scope item.
#
# Input format (per DESIGNER v2 usage docs,
# https://nyu-diffusionmri.github.io/DESIGNER-v2/docs/designer/usage/):
#   designer [options] input1,input2,... output
# Multiple DWI series are passed as a single, comma-separated list (no
# spaces) -- this is DESIGNER's native, documented multi-series mechanism.
# We therefore pass the two original shells directly from input/ and do NOT
# pre-concatenate them (see concatenate_inputs.sh and the plan's section 5
# for the fair-comparison rationale: DESIGNER should be exercised exactly as
# its own docs describe, not fed TORTOISE's intensity-harmonized file).
#
#   Series 28 (V6meso_RMR_b1_Delta63, 21 vols, b~1000)
#   Series 30 (V6meso_RMR_b2_Delta63, 62 vols, b~2000)
#
# -denoise:
#   MP-PCA denoising via dwidenoise. Default patch is a rectangular
#   ("box") kernel (5x5x5 unless overridden with -extent), the
#   `cordero-grande` MP-threshold algorithm -- matches the "MPPCA (box
#   patch)" scope item as-is, with no non-default flags.
#
# Docker image (pinned, per user's requirement -- do not change without
# being asked): nyudiffusionmri/designer2:v2.0.16

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_DIR="${SCRIPT_DIR}/input"
OUT_DIR="${SCRIPT_DIR}/output/designer_denoise"
DESIGNER_IMAGE="nyudiffusionmri/designer2:v2.0.16"

find_one() {
    local pattern="$1"
    local matches=()
    while IFS= read -r -d '' f; do
        matches+=("$f")
    done < <(find "${INPUT_DIR}" -maxdepth 1 -name "${pattern}" -print0)

    if [[ ${#matches[@]} -eq 0 ]]; then
        echo "ERROR: no file in ${INPUT_DIR} matching '${pattern}'" >&2
        exit 1
    elif [[ ${#matches[@]} -gt 1 ]]; then
        echo "ERROR: multiple files in ${INPUT_DIR} matching '${pattern}':" >&2
        printf '  %s\n' "${matches[@]}" >&2
        exit 1
    fi
    printf '%s\n' "${matches[0]}"
}

B1_NII="$(find_one '*_b1_*_28.nii')"
B2_NII="$(find_one '*_b2_*_30.nii')"

# Paths as seen inside the container (repo root bind-mounted at /data).
B1_REL="input/$(basename "${B1_NII}")"
B2_REL="input/$(basename "${B2_NII}")"

mkdir -p "${OUT_DIR}/scratch"

echo "== run_designer_denoise.sh =="
echo "Image:  ${DESIGNER_IMAGE}"
echo "Inputs: ${B1_REL} , ${B2_REL}  (native DESIGNER comma-list, not concatenated)"
echo "Step:   -denoise only (MP-PCA, default box patch)"
echo "Output: output/designer_denoise/dwi_denoised.nii"
echo

docker run --rm \
    --platform linux/amd64 \
    -v "${SCRIPT_DIR}:/data" \
    -w /data \
    "${DESIGNER_IMAGE}" \
    designer \
        -denoise \
        -algorithm veraart \
        -scratch /data/output/designer_denoise/scratch \
        -nocleanup \
        "/data/${B1_REL},/data/${B2_REL}" \
        /data/output/designer_denoise/dwi_denoised.nii
